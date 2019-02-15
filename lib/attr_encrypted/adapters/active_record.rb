if defined?(ActiveRecord::Base)
  module AttrEncrypted
    module Adapters
      module ActiveRecord
        def self.extended(base) # :nodoc:
          base.class_eval do

            # https://github.com/attr-encrypted/attr_encrypted/issues/68
            alias_method :reload_without_attr_encrypted, :reload
            def reload(*args, &block)
              result = reload_without_attr_encrypted(*args, &block)
              self.class.encrypted_attributes.keys.each do |attribute_name|
                instance_variable_set("@#{attribute_name}", nil)
              end
              result
            end

            attr_encrypted_options[:encode] = true
            class << self
              alias_method :attr_encryptor, :attr_encrypted
              alias_method :undefine_attribute_methods, :reset_column_information if ::ActiveRecord::VERSION::STRING < "3"

              alias_method :method_missing_without_attr_encrypted, :method_missing
              alias_method :method_missing, :method_missing_with_attr_encrypted
            end

            def perform_attribute_assignment(method, new_attributes, *args)
              return if new_attributes.blank?

              send method, new_attributes.reject { |k, _|  self.class.encrypted_attributes.key?(k.to_sym) }, *args
              send method, new_attributes.reject { |k, _| !self.class.encrypted_attributes.key?(k.to_sym) }, *args
            end
            private :perform_attribute_assignment

            if ::ActiveRecord::VERSION::STRING < "3.0" || ::ActiveRecord::VERSION::STRING > "3.1"
              def assign_attributes_with_attr_encrypted(*args)
                perform_attribute_assignment :assign_attributes_without_attr_encrypted, *args
              end
            end

            alias_method :attributes_without_attr_encrypted=, :attributes=
            def attributes=(*args)
              perform_attribute_assignment :attributes_without_attr_encrypted=, *args
            end
          end
        end

        protected

          # <tt>attr_encrypted</tt> method
          def attr_encrypted(*attrs)
            super
            attrs_without_options = attrs.reject { |attr| attr.is_a?(Hash) }

            attrs_without_options.each do |attr|
              alias_method "#{attr}_before_type_cast", attr

              options = encrypted_attributes[attr.to_sym]

              if ::ActiveRecord::VERSION::STRING < "5.1.6.1"
                define_method("#{attr}_changed?") do
                  send(attr) != decrypt(attr, send("#{options[:attribute]}_was"))
                end
              else
                define_method("will_save_change_to_#{attr}?") do
                  send(attr) != decrypt(attr, send("#{options[:attribute]}_in_database"))
                end
              end
            end
          end

          def attribute_instance_methods_as_symbols
            # We add accessor methods of the db columns to the list of instance
            # methods returned to let ActiveRecord define the accessor methods
            # for the db columns

            # Use with_connection so the connection doesn't stay pinned to the thread.
            connected = ::ActiveRecord::Base.connection_pool.with_connection(&:active?) rescue false

            if defined?(Rails) && Rails.logger && name == "DataSnapshot"
              Rails.logger.info "DataSnapshot - ActiveRecord.attribute_instance_methods_as_symbols connected: #{connected.inspect}"
              Rails.logger.info "DataSnapshot - ActiveRecord.attribute_instance_methods_as_symbols table_exists: #{table_exists?.inspect}" if connected
            end

            if connected && table_exists?
              columns_hash.keys.inject(super) {|instance_methods, column_name| instance_methods.concat [column_name.to_sym, :"#{column_name}="]}
            else
              if defined?(Rails) && Rails.logger && name == "DataSnapshot"
                Rails.logger.info "DataSnapshot - super attribute_instance_methods_as_symbols method"
              end

              super
            end
          end

          # Allows you to use dynamic methods like <tt>find_by_email</tt> or <tt>scoped_by_email</tt> for
          # encrypted attributes
          #
          # NOTE: This only works when the <tt>:key</tt> option is specified as a string (see the README)
          #
          # This is useful for encrypting fields like email addresses. Your user's email addresses
          # are encrypted in the database, but you can still look up a user by email for logging in
          #
          # Example
          #
          #   class User < ActiveRecord::Base
          #     attr_encrypted :email, :key => 'secret key'
          #   end
          #
          #   User.find_by_email_and_password('test@example.com', 'testing')
          #   # results in a call to
          #   User.find_by_encrypted_email_and_password('the_encrypted_version_of_test@example.com', 'testing')
          def method_missing_with_attr_encrypted(method, *args, &block)
            if match = /^(find|scoped)_(all_by|by)_([_a-zA-Z]\w*)$/.match(method.to_s)
              attribute_names = match.captures.last.split('_and_')
              attribute_names.each_with_index do |attribute, index|
                if attr_encrypted?(attribute)
                  args[index] = send("encrypt_#{attribute}", args[index])
                  attribute_names[index] = encrypted_attributes[attribute.to_sym][:attribute]
                end
              end
              method = "#{match.captures[0]}_#{match.captures[1]}_#{attribute_names.join('_and_')}".to_sym
            end
            method_missing_without_attr_encrypted(method, *args, &block)
          end
      end
    end
  end

  ActiveRecord::Base.extend AttrEncrypted::Adapters::ActiveRecord
end
