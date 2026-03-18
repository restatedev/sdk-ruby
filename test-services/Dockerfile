# ── Build stage: compile native extension ──
FROM ruby:3.3-bookworm AS build-sdk

# Install Rust toolchain and build dependencies
RUN apt-get update -y && \
    apt-get install -y build-essential curl clang && \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && \
    rm -rf /var/lib/apt/lists/*

ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /usr/src/sdk

# Copy the SDK source
COPY Cargo.toml Cargo.lock ./
COPY ext/ ./ext/
COPY lib/ ./lib/
COPY Gemfile Gemfile.lock ./
COPY restate-sdk.gemspec ./
COPY Rakefile ./
COPY LICENSE ./

# Install Ruby dependencies and compile native extension
RUN bundle install && bundle exec rake compile

# ── Runtime stage ──
FROM ruby:3.3-slim-bookworm AS test-services

# Install build tools for native gem extensions (e.g. json)
RUN apt-get update -y && \
    apt-get install -y build-essential && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /usr/src/app

# Copy the built SDK (with compiled native extension)
COPY --from=build-sdk /usr/src/sdk /usr/src/sdk
COPY --from=build-sdk /usr/local/bundle /usr/local/bundle

# Copy test-services
COPY test-services/ .

# Install test-services dependencies (restate-sdk from local path)
RUN bundle install

# Make entrypoint executable
RUN chmod +x entrypoint.sh

EXPOSE 9080
ENV RESTATE_CORE_LOG=debug
ENV RUST_BACKTRACE=1
ENV PORT=9080

ENTRYPOINT ["./entrypoint.sh"]
