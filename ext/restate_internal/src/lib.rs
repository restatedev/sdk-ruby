use magnus::{
    function, method,
    prelude::*,
    value::ReprValue,
    Error, ExceptionClass, Module, Object, RArray, RString, Ruby, Value,
};
use restate_sdk_shared_core::{
    CallHandle, CoreVM, DoProgressResponse, Error as CoreError, Header, IdentityVerifier, Input,
    NonEmptyValue, NotificationHandle, ResponseHead, RetryPolicy, RunExitResult,
    TakeOutputResult, Target, TerminalFailure, VMOptions, Value as CoreValue, VM,
    CANCEL_NOTIFICATION_HANDLE,
};
use std::cell::RefCell;
use std::fmt;
use std::sync::OnceLock;
use std::time::{Duration, SystemTime};

// Current crate version
const CURRENT_VERSION: &str = env!("CARGO_PKG_VERSION");

// ── Exception classes stored in OnceLock ──
// ExceptionClass contains NonNull<RBasic> which is !Send+!Sync,
// but Ruby exception classes are global and only accessed under the GVL.

struct SyncExceptionClass(ExceptionClass);
unsafe impl Send for SyncExceptionClass {}
unsafe impl Sync for SyncExceptionClass {}

static VM_ERROR_CLASS: OnceLock<SyncExceptionClass> = OnceLock::new();
static IDENTITY_KEY_ERROR_CLASS: OnceLock<SyncExceptionClass> = OnceLock::new();
static IDENTITY_VERIFICATION_ERROR_CLASS: OnceLock<SyncExceptionClass> = OnceLock::new();

fn vm_error_class() -> ExceptionClass {
    VM_ERROR_CLASS.get().expect("VM_ERROR_CLASS not initialized").0
}

fn identity_key_error_class() -> ExceptionClass {
    IDENTITY_KEY_ERROR_CLASS
        .get()
        .expect("IDENTITY_KEY_ERROR_CLASS not initialized")
        .0
}

fn identity_verification_error_class() -> ExceptionClass {
    IDENTITY_VERIFICATION_ERROR_CLASS
        .get()
        .expect("IDENTITY_VERIFICATION_ERROR_CLASS not initialized")
        .0
}

// ── Data wrappers ──

#[magnus::wrap(class = "Restate::Internal::Header")]
#[derive(Clone)]
struct RbHeader {
    key: String,
    value: String,
}

impl RbHeader {
    fn new(key: String, value: String) -> Self {
        Self { key, value }
    }
    fn key(&self) -> &str {
        &self.key
    }
    fn value(&self) -> &str {
        &self.value
    }
}

impl From<Header> for RbHeader {
    fn from(h: Header) -> Self {
        RbHeader {
            key: h.key.into(),
            value: h.value.into(),
        }
    }
}

impl From<RbHeader> for Header {
    fn from(h: RbHeader) -> Self {
        Header {
            key: h.key.into(),
            value: h.value.into(),
        }
    }
}

#[magnus::wrap(class = "Restate::Internal::ResponseHead")]
struct RbResponseHead {
    status_code: u16,
    headers: Vec<(String, String)>,
}

impl RbResponseHead {
    fn status_code(&self) -> u16 {
        self.status_code
    }
    fn headers_array(&self) -> Result<RArray, Error> {
        let ruby = Ruby::get().map_err(|_| Error::new(vm_error_class(), "Ruby not available"))?;
        let ary = ruby.ary_new_capa(self.headers.len());
        for (k, v) in &self.headers {
            let pair = ruby.ary_new_capa(2);
            pair.push(ruby.str_new(k))?;
            pair.push(ruby.str_new(v))?;
            ary.push(pair)?;
        }
        Ok(ary)
    }
}

impl From<ResponseHead> for RbResponseHead {
    fn from(rh: ResponseHead) -> Self {
        RbResponseHead {
            status_code: rh.status_code,
            headers: rh
                .headers
                .into_iter()
                .map(|Header { key, value }| (key.into(), value.into()))
                .collect(),
        }
    }
}

#[magnus::wrap(class = "Restate::Internal::Failure")]
#[derive(Clone)]
struct RbFailure {
    code: u16,
    message: String,
    stacktrace: Option<String>,
}

impl RbFailure {
    fn code(&self) -> u16 {
        self.code
    }
    fn message(&self) -> &str {
        &self.message
    }
    fn stacktrace(&self) -> Option<&str> {
        self.stacktrace.as_deref()
    }
}

impl From<TerminalFailure> for RbFailure {
    fn from(f: TerminalFailure) -> Self {
        RbFailure {
            code: f.code,
            message: f.message,
            stacktrace: None,
        }
    }
}

impl From<RbFailure> for TerminalFailure {
    fn from(f: RbFailure) -> Self {
        TerminalFailure {
            code: f.code,
            message: f.message,
            metadata: vec![],
        }
    }
}

impl From<RbFailure> for CoreError {
    fn from(f: RbFailure) -> Self {
        let mut e = Self::new(f.code, f.message);
        if let Some(stacktrace) = f.stacktrace {
            e = e.with_stacktrace(stacktrace);
        }
        e
    }
}

#[magnus::wrap(class = "Restate::Internal::Void")]
struct RbVoid;

#[magnus::wrap(class = "Restate::Internal::Suspended")]
struct RbSuspended;

#[magnus::wrap(class = "Restate::Internal::StateKeys")]
#[derive(Clone)]
struct RbStateKeys {
    keys: Vec<String>,
}

impl RbStateKeys {
    fn keys_array(&self) -> Result<RArray, Error> {
        let ruby = Ruby::get().map_err(|_| Error::new(vm_error_class(), "Ruby not available"))?;
        let ary = ruby.ary_new_capa(self.keys.len());
        for k in &self.keys {
            ary.push(ruby.str_new(k))?;
        }
        Ok(ary)
    }
}

#[magnus::wrap(class = "Restate::Internal::Input")]
struct RbInput {
    invocation_id: String,
    random_seed: u64,
    key: String,
    headers: Vec<RbHeader>,
    input: Vec<u8>,
}

impl RbInput {
    fn invocation_id(&self) -> &str {
        &self.invocation_id
    }
    fn random_seed(&self) -> u64 {
        self.random_seed
    }
    fn key(&self) -> &str {
        &self.key
    }
    fn headers_array(&self) -> Result<RArray, Error> {
        let ruby = Ruby::get().map_err(|_| Error::new(vm_error_class(), "Ruby not available"))?;
        let ary = ruby.ary_new_capa(self.headers.len());
        for h in &self.headers {
            ary.push(RbHeader::new(h.key.clone(), h.value.clone()))?;
        }
        Ok(ary)
    }
    fn input_bytes(&self) -> Result<RString, Error> {
        let ruby = Ruby::get().map_err(|_| Error::new(vm_error_class(), "Ruby not available"))?;
        Ok(ruby.str_from_slice(&self.input))
    }
}

impl From<Input> for RbInput {
    fn from(i: Input) -> Self {
        RbInput {
            invocation_id: i.invocation_id,
            random_seed: i.random_seed,
            key: i.key,
            headers: i.headers.into_iter().map(Into::into).collect(),
            input: i.input.into(),
        }
    }
}

#[magnus::wrap(class = "Restate::Internal::ExponentialRetryConfig")]
#[derive(Clone)]
struct RbExponentialRetryConfig {
    initial_interval: Option<u64>,
    max_attempts: Option<u32>,
    max_duration: Option<u64>,
    max_interval: Option<u64>,
    factor: Option<f64>,
}

impl RbExponentialRetryConfig {
    fn initial_interval(&self) -> Option<u64> {
        self.initial_interval
    }
    fn max_attempts(&self) -> Option<u32> {
        self.max_attempts
    }
    fn max_duration(&self) -> Option<u64> {
        self.max_duration
    }
    fn max_interval(&self) -> Option<u64> {
        self.max_interval
    }
    fn factor(&self) -> Option<f64> {
        self.factor
    }
}

impl From<RbExponentialRetryConfig> for RetryPolicy {
    fn from(value: RbExponentialRetryConfig) -> Self {
        if value.initial_interval.is_some()
            || value.max_attempts.is_some()
            || value.max_duration.is_some()
            || value.max_interval.is_some()
            || value.factor.is_some()
        {
            RetryPolicy::Exponential {
                initial_interval: Duration::from_millis(value.initial_interval.unwrap_or(50)),
                max_attempts: value.max_attempts,
                max_duration: value.max_duration.map(Duration::from_millis),
                factor: value.factor.unwrap_or(2.0) as f32,
                max_interval: value
                    .max_interval
                    .map(Duration::from_millis)
                    .or_else(|| Some(Duration::from_secs(10))),
            }
        } else {
            RetryPolicy::Infinite
        }
    }
}

// ── Progress types ──

#[magnus::wrap(class = "Restate::Internal::DoProgressAnyCompleted")]
struct RbDoProgressAnyCompleted;

#[magnus::wrap(class = "Restate::Internal::DoProgressReadFromInput")]
struct RbDoProgressReadFromInput;

#[magnus::wrap(class = "Restate::Internal::DoProgressExecuteRun")]
struct RbDoProgressExecuteRun {
    handle: u32,
}

impl RbDoProgressExecuteRun {
    fn handle(&self) -> u32 {
        self.handle
    }
}

#[magnus::wrap(class = "Restate::Internal::DoProgressCancelSignalReceived")]
struct RbDoProgressCancelSignalReceived;

#[magnus::wrap(class = "Restate::Internal::DoWaitForPendingRun")]
struct RbDoWaitForPendingRun;

#[magnus::wrap(class = "Restate::Internal::CallHandle")]
struct RbCallHandle {
    invocation_id_handle: u32,
    result_handle: u32,
}

impl RbCallHandle {
    fn invocation_id_handle(&self) -> u32 {
        self.invocation_id_handle
    }
    fn result_handle(&self) -> u32 {
        self.result_handle
    }
}

impl From<CallHandle> for RbCallHandle {
    fn from(h: CallHandle) -> Self {
        RbCallHandle {
            invocation_id_handle: h.invocation_id_notification_handle.into(),
            result_handle: h.call_notification_handle.into(),
        }
    }
}

// ── VM ──

#[magnus::wrap(class = "Restate::Internal::VM")]
struct RbVM {
    vm: RefCell<CoreVM>,
}

fn core_error_to_magnus(e: CoreError) -> Error {
    Error::new(vm_error_class(), e.to_string())
}

impl RbVM {
    fn new(ruby: &Ruby, headers: RArray) -> Result<Self, Error> {
        let mut hdr_vec: Vec<(String, String)> = Vec::new();
        for item in headers.into_iter() {
            let pair = RArray::try_convert(item)?;
            if pair.len() != 2 {
                return Err(Error::new(
                    ruby.exception_arg_error(),
                    "Each header must be a [key, value] pair",
                ));
            }
            let k: String = pair.entry(0)?;
            let v: String = pair.entry(1)?;
            hdr_vec.push((k, v));
        }
        let vm =
            CoreVM::new(hdr_vec, VMOptions::default()).map_err(core_error_to_magnus)?;
        Ok(Self {
            vm: RefCell::new(vm),
        })
    }

    fn get_response_head(&self) -> RbResponseHead {
        self.vm.borrow().get_response_head().into()
    }

    fn notify_input(&self, buffer: RString) {
        let bytes: Vec<u8> = unsafe { buffer.as_slice().to_vec() };
        self.vm.borrow_mut().notify_input(bytes.into());
    }

    fn notify_input_closed(&self) {
        self.vm.borrow_mut().notify_input_closed();
    }

    // notify_error(error_str, stacktrace_or_nil)
    // Both parameters are always passed from Ruby (nil for no stacktrace).
    fn notify_error(&self, error: String, stacktrace: Value) {
        let st: Option<String> = if stacktrace.is_nil() {
            None
        } else {
            Some(String::try_convert(stacktrace).unwrap_or_default())
        };
        let mut err = CoreError::new(restate_sdk_shared_core::error::codes::INTERNAL, error);
        if let Some(s) = st {
            err = err.with_stacktrace(s);
        }
        CoreVM::notify_error(&mut *self.vm.borrow_mut(), err, None);
    }

    fn take_output(&self) -> Result<Value, Error> {
        let ruby = Ruby::get().map_err(|_| Error::new(vm_error_class(), "Ruby not available"))?;
        Ok(match self.vm.borrow_mut().take_output() {
            TakeOutputResult::Buffer(b) => ruby.str_from_slice(&b).as_value(),
            TakeOutputResult::EOF => ruby.qnil().as_value(),
        })
    }

    fn is_ready_to_execute(&self) -> Result<bool, Error> {
        self.vm
            .borrow()
            .is_ready_to_execute()
            .map_err(core_error_to_magnus)
    }

    fn is_completed(&self, handle: u32) -> bool {
        self.vm.borrow().is_completed(handle.into())
    }

    fn do_progress(&self, handles: RArray) -> Result<Value, Error> {
        let ruby = Ruby::get().map_err(|_| Error::new(vm_error_class(), "Ruby not available"))?;
        let handle_vec: Vec<u32> = handles.to_vec()?;
        let notification_handles: Vec<NotificationHandle> =
            handle_vec.into_iter().map(NotificationHandle::from).collect();

        let res = self.vm.borrow_mut().do_progress(notification_handles);

        match res {
            Err(e) if e.is_suspended_error() => Ok(ruby.into_value(RbSuspended)),
            Err(e) => Err(core_error_to_magnus(e)),
            Ok(DoProgressResponse::AnyCompleted) => {
                Ok(ruby.into_value(RbDoProgressAnyCompleted))
            }
            Ok(DoProgressResponse::ReadFromInput) => {
                Ok(ruby.into_value(RbDoProgressReadFromInput))
            }
            Ok(DoProgressResponse::ExecuteRun(handle)) => Ok(ruby.into_value(
                RbDoProgressExecuteRun {
                    handle: handle.into(),
                },
            )),
            Ok(DoProgressResponse::CancelSignalReceived) => {
                Ok(ruby.into_value(RbDoProgressCancelSignalReceived))
            }
            Ok(DoProgressResponse::WaitingPendingRun) => {
                Ok(ruby.into_value(RbDoWaitForPendingRun))
            }
        }
    }

    fn take_notification(&self, handle: u32) -> Result<Value, Error> {
        let ruby = Ruby::get().map_err(|_| Error::new(vm_error_class(), "Ruby not available"))?;
        let res = self
            .vm
            .borrow_mut()
            .take_notification(NotificationHandle::from(handle));

        match res {
            Err(e) if e.is_suspended_error() => Ok(ruby.into_value(RbSuspended)),
            Err(e) => Err(core_error_to_magnus(e)),
            Ok(None) => Ok(ruby.qnil().as_value()),
            Ok(Some(CoreValue::Void)) => Ok(ruby.into_value(RbVoid)),
            Ok(Some(CoreValue::Success(b))) => Ok(ruby.str_from_slice(&b).as_value()),
            Ok(Some(CoreValue::Failure(f))) => Ok(ruby.into_value(RbFailure::from(f))),
            Ok(Some(CoreValue::StateKeys(keys))) => {
                Ok(ruby.into_value(RbStateKeys { keys }))
            }
            Ok(Some(CoreValue::InvocationId(id))) => Ok(ruby.str_new(&id).as_value()),
        }
    }

    // Syscalls

    fn sys_input(&self) -> Result<RbInput, Error> {
        self.vm
            .borrow_mut()
            .sys_input()
            .map(Into::into)
            .map_err(core_error_to_magnus)
    }

    fn sys_get_state(&self, key: String) -> Result<u32, Error> {
        self.vm
            .borrow_mut()
            .sys_state_get(key, Default::default())
            .map(Into::into)
            .map_err(core_error_to_magnus)
    }

    fn sys_get_state_keys(&self) -> Result<u32, Error> {
        self.vm
            .borrow_mut()
            .sys_state_get_keys()
            .map(Into::into)
            .map_err(core_error_to_magnus)
    }

    fn sys_set_state(&self, key: String, buffer: RString) -> Result<(), Error> {
        let bytes: Vec<u8> = unsafe { buffer.as_slice().to_vec() };
        self.vm
            .borrow_mut()
            .sys_state_set(key, bytes.into(), Default::default())
            .map_err(core_error_to_magnus)
    }

    fn sys_clear_state(&self, key: String) -> Result<(), Error> {
        self.vm
            .borrow_mut()
            .sys_state_clear(key)
            .map_err(core_error_to_magnus)
    }

    fn sys_clear_all_state(&self) -> Result<(), Error> {
        self.vm
            .borrow_mut()
            .sys_state_clear_all()
            .map_err(core_error_to_magnus)
    }

    // sys_sleep(millis, name_or_nil)
    fn sys_sleep(&self, millis: u64, name: Value) -> Result<u32, Error> {
        let name_str: Option<String> = if name.is_nil() {
            None
        } else {
            Some(String::try_convert(name).unwrap_or_default())
        };
        let now = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .expect("Duration since unix epoch cannot fail");
        self.vm
            .borrow_mut()
            .sys_sleep(
                name_str.unwrap_or_default(),
                now + Duration::from_millis(millis),
                Some(now),
            )
            .map(Into::into)
            .map_err(core_error_to_magnus)
    }

    // sys_call(service, handler, buffer, key_or_nil, idempotency_key_or_nil, headers_or_nil)
    fn sys_call(
        &self,
        service: String,
        handler: String,
        buffer: RString,
        key: Value,
        idempotency_key: Value,
        headers: Value,
    ) -> Result<RbCallHandle, Error> {
        let bytes: Vec<u8> = unsafe { buffer.as_slice().to_vec() };
        let key_opt: Option<String> = if key.is_nil() {
            None
        } else {
            Some(String::try_convert(key)?)
        };
        let idem_opt: Option<String> = if idempotency_key.is_nil() {
            None
        } else {
            Some(String::try_convert(idempotency_key)?)
        };
        let hdr_vec = if headers.is_nil() {
            vec![]
        } else {
            parse_headers_array(RArray::try_convert(headers)?)?
        };
        self.vm
            .borrow_mut()
            .sys_call(
                Target {
                    service,
                    handler,
                    key: key_opt,
                    idempotency_key: idem_opt,
                    headers: hdr_vec,
                },
                bytes.into(),
                Default::default(),
            )
            .map(Into::into)
            .map_err(core_error_to_magnus)
    }

    // sys_send(service, handler, buffer, key_or_nil, delay_or_nil, idempotency_key_or_nil, headers_or_nil)
    fn sys_send(
        &self,
        service: String,
        handler: String,
        buffer: RString,
        key: Value,
        delay: Value,
        idempotency_key: Value,
        headers: Value,
    ) -> Result<u32, Error> {
        let bytes: Vec<u8> = unsafe { buffer.as_slice().to_vec() };
        let key_opt: Option<String> = if key.is_nil() {
            None
        } else {
            Some(String::try_convert(key)?)
        };
        let delay_opt: Option<u64> = if delay.is_nil() {
            None
        } else {
            Some(u64::try_convert(delay)?)
        };
        let idem_opt: Option<String> = if idempotency_key.is_nil() {
            None
        } else {
            Some(String::try_convert(idempotency_key)?)
        };
        let hdr_vec = if headers.is_nil() {
            vec![]
        } else {
            parse_headers_array(RArray::try_convert(headers)?)?
        };
        self.vm
            .borrow_mut()
            .sys_send(
                Target {
                    service,
                    handler,
                    key: key_opt,
                    idempotency_key: idem_opt,
                    headers: hdr_vec,
                },
                bytes.into(),
                delay_opt.map(|millis| {
                    SystemTime::now()
                        .duration_since(SystemTime::UNIX_EPOCH)
                        .expect("Duration since unix epoch cannot fail")
                        + Duration::from_millis(millis)
                }),
                Default::default(),
            )
            .map(|s| s.invocation_id_notification_handle.into())
            .map_err(core_error_to_magnus)
    }

    fn sys_run(&self, name: String) -> Result<u32, Error> {
        self.vm
            .borrow_mut()
            .sys_run(name)
            .map(Into::into)
            .map_err(core_error_to_magnus)
    }

    fn propose_run_completion_success(&self, handle: u32, buffer: RString) -> Result<(), Error> {
        let bytes: Vec<u8> = unsafe { buffer.as_slice().to_vec() };
        CoreVM::propose_run_completion(
            &mut *self.vm.borrow_mut(),
            handle.into(),
            RunExitResult::Success(bytes.into()),
            RetryPolicy::None,
        )
        .map_err(core_error_to_magnus)
    }

    fn propose_run_completion_failure(&self, handle: u32, failure: &RbFailure) -> Result<(), Error> {
        self.vm
            .borrow_mut()
            .propose_run_completion(
                handle.into(),
                RunExitResult::TerminalFailure(failure.clone().into()),
                RetryPolicy::None,
            )
            .map_err(core_error_to_magnus)
    }

    fn propose_run_completion_failure_transient(
        &self,
        handle: u32,
        failure: &RbFailure,
        attempt_duration: u64,
        config: &RbExponentialRetryConfig,
    ) -> Result<(), Error> {
        self.vm
            .borrow_mut()
            .propose_run_completion(
                handle.into(),
                RunExitResult::RetryableFailure {
                    attempt_duration: Duration::from_millis(attempt_duration),
                    error: failure.clone().into(),
                },
                config.clone().into(),
            )
            .map_err(core_error_to_magnus)
    }

    fn sys_write_output_success(&self, buffer: RString) -> Result<(), Error> {
        let bytes: Vec<u8> = unsafe { buffer.as_slice().to_vec() };
        self.vm
            .borrow_mut()
            .sys_write_output(NonEmptyValue::Success(bytes.into()), Default::default())
            .map_err(core_error_to_magnus)
    }

    fn sys_write_output_failure(&self, failure: &RbFailure) -> Result<(), Error> {
        self.vm
            .borrow_mut()
            .sys_write_output(
                NonEmptyValue::Failure(failure.clone().into()),
                Default::default(),
            )
            .map_err(core_error_to_magnus)
    }

    fn sys_end(&self) -> Result<(), Error> {
        self.vm.borrow_mut().sys_end().map_err(core_error_to_magnus)
    }

    fn is_replaying(&self) -> bool {
        self.vm.borrow().is_replaying()
    }

    // ── Awakeables ──

    fn sys_awakeable(&self) -> Result<Value, Error> {
        let ruby = Ruby::get().map_err(|_| Error::new(vm_error_class(), "Ruby not available"))?;
        let (id, handle) = self
            .vm
            .borrow_mut()
            .sys_awakeable()
            .map_err(core_error_to_magnus)?;
        let ary = ruby.ary_new_capa(2);
        ary.push(ruby.str_new(&id))?;
        ary.push(u32::from(handle))?;
        Ok(ary.as_value())
    }

    fn sys_complete_awakeable_success(&self, id: String, buffer: RString) -> Result<(), Error> {
        let bytes: Vec<u8> = unsafe { buffer.as_slice().to_vec() };
        self.vm
            .borrow_mut()
            .sys_complete_awakeable(id, NonEmptyValue::Success(bytes.into()), Default::default())
            .map_err(core_error_to_magnus)
    }

    fn sys_complete_awakeable_failure(&self, id: String, failure: &RbFailure) -> Result<(), Error> {
        self.vm
            .borrow_mut()
            .sys_complete_awakeable(
                id,
                NonEmptyValue::Failure(failure.clone().into()),
                Default::default(),
            )
            .map_err(core_error_to_magnus)
    }

    // ── Promises ──

    fn sys_get_promise(&self, key: String) -> Result<u32, Error> {
        self.vm
            .borrow_mut()
            .sys_get_promise(key)
            .map(Into::into)
            .map_err(core_error_to_magnus)
    }

    fn sys_peek_promise(&self, key: String) -> Result<u32, Error> {
        self.vm
            .borrow_mut()
            .sys_peek_promise(key)
            .map(Into::into)
            .map_err(core_error_to_magnus)
    }

    fn sys_complete_promise_success(&self, key: String, buffer: RString) -> Result<u32, Error> {
        let bytes: Vec<u8> = unsafe { buffer.as_slice().to_vec() };
        self.vm
            .borrow_mut()
            .sys_complete_promise(key, NonEmptyValue::Success(bytes.into()), Default::default())
            .map(Into::into)
            .map_err(core_error_to_magnus)
    }

    fn sys_complete_promise_failure(
        &self,
        key: String,
        failure: &RbFailure,
    ) -> Result<u32, Error> {
        self.vm
            .borrow_mut()
            .sys_complete_promise(
                key,
                NonEmptyValue::Failure(failure.clone().into()),
                Default::default(),
            )
            .map(Into::into)
            .map_err(core_error_to_magnus)
    }

    // ── Cancel invocation ──

    fn sys_cancel_invocation(&self, target_invocation_id: String) -> Result<(), Error> {
        self.vm
            .borrow_mut()
            .sys_cancel_invocation(target_invocation_id)
            .map_err(core_error_to_magnus)
    }
}

// ── Identity Verifier ──

#[magnus::wrap(class = "Restate::Internal::IdentityVerifier")]
struct RbIdentityVerifier {
    verifier: IdentityVerifier,
}

impl RbIdentityVerifier {
    fn new(keys: RArray) -> Result<Self, Error> {
        let key_strings: Vec<String> = keys.to_vec()?;
        let key_refs: Vec<&str> = key_strings.iter().map(|s| s.as_str()).collect();
        let verifier = IdentityVerifier::new(&key_refs)
            .map_err(|e| Error::new(identity_key_error_class(), e.to_string()))?;
        Ok(Self { verifier })
    }

    fn verify(&self, headers: RArray, path: String) -> Result<(), Error> {
        let mut hdr_vec: Vec<(String, String)> = Vec::new();
        for item in headers.into_iter() {
            let pair = RArray::try_convert(item)?;
            let k: String = pair.entry(0)?;
            let v: String = pair.entry(1)?;
            hdr_vec.push((k, v));
        }
        self.verifier
            .verify_identity(&hdr_vec, &path)
            .map_err(|e| Error::new(identity_verification_error_class(), e.to_string()))
    }
}

// ── Error formatter ──

use restate_sdk_shared_core::fmt::{set_error_formatter, ErrorFormatter};

#[derive(Debug)]
struct RubyErrorFormatter;

impl ErrorFormatter for RubyErrorFormatter {
    fn display_closed_error(&self, f: &mut fmt::Formatter<'_>, event: &str) -> fmt::Result {
        write!(f, "Execution is suspended, but the handler is still attempting to make progress (calling '{event}'). This can happen:

* If you use a bare rescue that catches all exceptions.
Don't do:
begin
  # Code
rescue => e
  # This catches all exceptions, including internal Restate exceptions!
  # '{event}' <- This operation prints this exception
end

Do instead:
begin
  # Code
rescue Restate::TerminalError => e
  # In Restate handlers you typically want to catch TerminalError only
end

Or remove the begin/rescue altogether if you don't need it.

* If you use the context after the handler completed, e.g. passing the context to another thread.
  Check https://docs.restate.dev/develop/ruby/error-handling for more details.")
    }
}

// ── Helpers ──

fn parse_headers_array(ary: RArray) -> Result<Vec<Header>, Error> {
    let mut result = Vec::new();
    for item in ary.into_iter() {
        let pair = RArray::try_convert(item)?;
        let k: String = pair.entry(0)?;
        let v: String = pair.entry(1)?;
        result.push(Header {
            key: k.into(),
            value: v.into(),
        });
    }
    Ok(result)
}

// Constructor functions (free functions for use with function! macro)

fn rb_failure_new(code: u16, message: String, stacktrace: Value) -> RbFailure {
    let st = if stacktrace.is_nil() {
        None
    } else {
        Some(String::try_convert(stacktrace).unwrap_or_default())
    };
    RbFailure {
        code,
        message,
        stacktrace: st,
    }
}

fn rb_exponential_retry_config_new(
    initial_interval: Value,
    max_attempts: Value,
    max_duration: Value,
    max_interval: Value,
    factor: Value,
) -> RbExponentialRetryConfig {
    let to_opt_u64 = |v: Value| -> Option<u64> {
        if v.is_nil() { None } else { u64::try_convert(v).ok() }
    };
    let to_opt_u32 = |v: Value| -> Option<u32> {
        if v.is_nil() { None } else { u32::try_convert(v).ok() }
    };
    let to_opt_f64 = |v: Value| -> Option<f64> {
        if v.is_nil() { None } else { f64::try_convert(v).ok() }
    };
    RbExponentialRetryConfig {
        initial_interval: to_opt_u64(initial_interval),
        max_attempts: to_opt_u32(max_attempts),
        max_duration: to_opt_u64(max_duration),
        max_interval: to_opt_u64(max_interval),
        factor: to_opt_f64(factor),
    }
}

// ── Module init ──

#[magnus::init(name = "restate_internal")]
fn init(ruby: &Ruby) -> Result<(), Error> {
    use tracing_subscriber::EnvFilter;

    let _ = tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_env("RESTATE_CORE_LOG"))
        .try_init();

    let restate = ruby.define_module("Restate")?;
    let internal = restate.define_module("Internal")?;

    // Initialize exception classes
    let vm_err = internal.define_error("VMError", ruby.exception_runtime_error())?;
    let _ = VM_ERROR_CLASS.set(SyncExceptionClass(vm_err));

    let ik_err = internal.define_error("IdentityKeyError", ruby.exception_runtime_error())?;
    let _ = IDENTITY_KEY_ERROR_CLASS.set(SyncExceptionClass(ik_err));

    let iv_err =
        internal.define_error("IdentityVerificationError", ruby.exception_runtime_error())?;
    let _ = IDENTITY_VERIFICATION_ERROR_CLASS.set(SyncExceptionClass(iv_err));

    // Header
    let header_class = internal.define_class("Header", ruby.class_object())?;
    header_class.define_singleton_method("new", function!(RbHeader::new, 2))?;
    header_class.define_method("key", method!(RbHeader::key, 0))?;
    header_class.define_method("value", method!(RbHeader::value, 0))?;

    // ResponseHead
    let rh_class = internal.define_class("ResponseHead", ruby.class_object())?;
    rh_class.define_method("status_code", method!(RbResponseHead::status_code, 0))?;
    rh_class.define_method("headers", method!(RbResponseHead::headers_array, 0))?;

    // Failure - constructor takes (code, message, stacktrace_or_nil)
    let failure_class = internal.define_class("Failure", ruby.class_object())?;
    failure_class.define_singleton_method("new", function!(rb_failure_new, 3))?;
    failure_class.define_method("code", method!(RbFailure::code, 0))?;
    failure_class.define_method("message", method!(RbFailure::message, 0))?;
    failure_class.define_method("stacktrace", method!(RbFailure::stacktrace, 0))?;

    // Void, Suspended, StateKeys
    internal.define_class("Void", ruby.class_object())?;
    internal.define_class("Suspended", ruby.class_object())?;
    let sk_class = internal.define_class("StateKeys", ruby.class_object())?;
    sk_class.define_method("keys", method!(RbStateKeys::keys_array, 0))?;

    // Input
    let input_class = internal.define_class("Input", ruby.class_object())?;
    input_class.define_method("invocation_id", method!(RbInput::invocation_id, 0))?;
    input_class.define_method("random_seed", method!(RbInput::random_seed, 0))?;
    input_class.define_method("key", method!(RbInput::key, 0))?;
    input_class.define_method("headers", method!(RbInput::headers_array, 0))?;
    input_class.define_method("input", method!(RbInput::input_bytes, 0))?;

    // ExponentialRetryConfig - constructor takes all 5 params (nil for unset)
    let erc_class = internal.define_class("ExponentialRetryConfig", ruby.class_object())?;
    erc_class
        .define_singleton_method("new", function!(rb_exponential_retry_config_new, 5))?;
    erc_class
        .define_method("initial_interval", method!(RbExponentialRetryConfig::initial_interval, 0))?;
    erc_class.define_method("max_attempts", method!(RbExponentialRetryConfig::max_attempts, 0))?;
    erc_class.define_method("max_duration", method!(RbExponentialRetryConfig::max_duration, 0))?;
    erc_class.define_method("max_interval", method!(RbExponentialRetryConfig::max_interval, 0))?;
    erc_class.define_method("factor", method!(RbExponentialRetryConfig::factor, 0))?;

    // Progress types
    internal.define_class("DoProgressAnyCompleted", ruby.class_object())?;
    internal.define_class("DoProgressReadFromInput", ruby.class_object())?;
    let exec_run_class = internal.define_class("DoProgressExecuteRun", ruby.class_object())?;
    exec_run_class.define_method("handle", method!(RbDoProgressExecuteRun::handle, 0))?;
    internal.define_class("DoProgressCancelSignalReceived", ruby.class_object())?;
    internal.define_class("DoWaitForPendingRun", ruby.class_object())?;

    // CallHandle
    let ch_class = internal.define_class("CallHandle", ruby.class_object())?;
    ch_class.define_method(
        "invocation_id_handle",
        method!(RbCallHandle::invocation_id_handle, 0),
    )?;
    ch_class.define_method("result_handle", method!(RbCallHandle::result_handle, 0))?;

    // VM - all methods use explicit arities
    let vm_class = internal.define_class("VM", ruby.class_object())?;
    vm_class.define_singleton_method("new", function!(RbVM::new, 1))?;
    vm_class.define_method("get_response_head", method!(RbVM::get_response_head, 0))?;
    vm_class.define_method("notify_input", method!(RbVM::notify_input, 1))?;
    vm_class.define_method("notify_input_closed", method!(RbVM::notify_input_closed, 0))?;
    vm_class.define_method("notify_error", method!(RbVM::notify_error, 2))?;
    vm_class.define_method("take_output", method!(RbVM::take_output, 0))?;
    vm_class.define_method("is_ready_to_execute", method!(RbVM::is_ready_to_execute, 0))?;
    vm_class.define_method("is_completed", method!(RbVM::is_completed, 1))?;
    vm_class.define_method("do_progress", method!(RbVM::do_progress, 1))?;
    vm_class.define_method("take_notification", method!(RbVM::take_notification, 1))?;
    vm_class.define_method("sys_input", method!(RbVM::sys_input, 0))?;
    vm_class.define_method("sys_get_state", method!(RbVM::sys_get_state, 1))?;
    vm_class.define_method("sys_get_state_keys", method!(RbVM::sys_get_state_keys, 0))?;
    vm_class.define_method("sys_set_state", method!(RbVM::sys_set_state, 2))?;
    vm_class.define_method("sys_clear_state", method!(RbVM::sys_clear_state, 1))?;
    vm_class.define_method("sys_clear_all_state", method!(RbVM::sys_clear_all_state, 0))?;
    vm_class.define_method("sys_sleep", method!(RbVM::sys_sleep, 2))?;
    vm_class.define_method("sys_call", method!(RbVM::sys_call, 6))?;
    vm_class.define_method("sys_send", method!(RbVM::sys_send, 7))?;
    vm_class.define_method("sys_run", method!(RbVM::sys_run, 1))?;
    vm_class.define_method(
        "propose_run_completion_success",
        method!(RbVM::propose_run_completion_success, 2),
    )?;
    vm_class.define_method(
        "propose_run_completion_failure",
        method!(RbVM::propose_run_completion_failure, 2),
    )?;
    vm_class.define_method(
        "propose_run_completion_failure_transient",
        method!(RbVM::propose_run_completion_failure_transient, 4),
    )?;
    vm_class.define_method(
        "sys_write_output_success",
        method!(RbVM::sys_write_output_success, 1),
    )?;
    vm_class.define_method(
        "sys_write_output_failure",
        method!(RbVM::sys_write_output_failure, 1),
    )?;
    vm_class.define_method("sys_end", method!(RbVM::sys_end, 0))?;
    vm_class.define_method("is_replaying", method!(RbVM::is_replaying, 0))?;
    vm_class.define_method("sys_awakeable", method!(RbVM::sys_awakeable, 0))?;
    vm_class.define_method(
        "sys_complete_awakeable_success",
        method!(RbVM::sys_complete_awakeable_success, 2),
    )?;
    vm_class.define_method(
        "sys_complete_awakeable_failure",
        method!(RbVM::sys_complete_awakeable_failure, 2),
    )?;
    vm_class.define_method("sys_get_promise", method!(RbVM::sys_get_promise, 1))?;
    vm_class.define_method("sys_peek_promise", method!(RbVM::sys_peek_promise, 1))?;
    vm_class.define_method(
        "sys_complete_promise_success",
        method!(RbVM::sys_complete_promise_success, 2),
    )?;
    vm_class.define_method(
        "sys_complete_promise_failure",
        method!(RbVM::sys_complete_promise_failure, 2),
    )?;
    vm_class.define_method(
        "sys_cancel_invocation",
        method!(RbVM::sys_cancel_invocation, 1),
    )?;

    // IdentityVerifier
    let iv_class = internal.define_class("IdentityVerifier", ruby.class_object())?;
    iv_class.define_singleton_method("new", function!(RbIdentityVerifier::new, 1))?;
    iv_class.define_method("verify", method!(RbIdentityVerifier::verify, 2))?;

    // Constants
    internal.const_set("SDK_VERSION", CURRENT_VERSION)?;
    internal.const_set(
        "CANCEL_NOTIFICATION_HANDLE",
        u32::from(CANCEL_NOTIFICATION_HANDLE),
    )?;

    // Set customized error formatter
    set_error_formatter(RubyErrorFormatter);

    Ok(())
}
