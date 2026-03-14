# typed: true

module Tapioca
  module Dsl
    class Compiler
      def self.all_classes; end
      def self.gather_constants; end
      def root; end
      def constant; end
      def create_param(name, type:); end
      def decorate; end
    end
  end
end
