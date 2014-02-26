module Bequeath
  module TableInheritance
    module BaseClass

    # Invoked when TableInheritance is included in a class
    def self.included(base)
      base.extend ClassMethods
    end

    # Methods accessible at the class declaration level. Keep this to a
    # minimum so the mixin doesn't add any other code unless/until you
    # actually want it.
    module ClassMethods

      # A base class table has a standard auto-incrementing primary key (id) and contains
      # attributes that are common to its sublass models. In addition, it has a column named
      # +<base-class-model>_type+ which contains the class name of the subclass.
      #
      # The primary key of the base class table and the primary key of the subclass tables are
      # shared. Shared primary keys enforce the one-to-one nature of the base-class-to-subclass
      # relationship.
      #
      # The +acts_as_base_class+ macro declares that a model will behave as a base class table.
      # For example:
      #
      #   class Account < ActiveRecord::Base
      #     acts_as_base_class :subclasses => [:patient_accounts, :physician_accounts, :vendor_accounts]
      #   end
      #
      # In the example above, four tables are required in the schema. The 'accounts'
      # table provides the attributes common to all types of accounts.The three subclass
      # tables contain attributes specific to those account types. The +id+ column
      # of a row in a subclass table contains the same value as the +id+ column in
      # the corresponding row in the accounts table, so the subclass table +id+ column
      # serves as both a primary key and a foreign key. A column named 'account_type'
      # is used in the base class table to contain the model class name of the subclass
      # whose row is associated with the base class row.
      #
      # Other +acts_as_base_class+ options:
      #
      # [+:abstract+] By default, you can create a base class record without
      #               a corresponding subclass, i.e. the type field will be nil.
      #               This is usefult when your domain model allows a base
      #               class to "stand on its own'. However, when you set the
      #               +:abstract+ option to true, a base class record cannot
      #               be created without an accompanying subclass.
      #
      # [+:expose_methods+]  A list of base class model method names - lets subclasses
      #               "inherit" the specified base class methods.  These methods
      #               then become directly accessible on the subclass model by
      #               users of the subclass.
      #
      def acts_as_base_class(options = {})

        cattr_accessor :type_attribute        # name of the type column, e.g. "account_type"
        cattr_accessor :subclass_types        # array of this base class's subclasses or types
        cattr_accessor :baseclass_methods     # list of methods available to subclasses
        cattr_accessor :baseclass_options     # options provided to the macro

        self.type_attribute = (self.name.downcase + '_type').to_sym
        self.subclass_types = Array(options[:subclasses] || []).map! {|t| t.to_s.tableize.singularize.to_sym}
        self.baseclass_methods = Array(options[:expose_methods] || [])
        self.baseclass_options = options

        extend  BaseClass::SingletonMethods
        include BaseClass::InstanceMethods

        # Do the has_one for each subclass; add subclass specific scope
        subclass_types.each do |subclass|
          has_one subclass, :foreign_key => :id, :inverse_of => self.table_name.singularize.to_sym
          scope "by_#{subclass}".to_sym, -> {where(type_attribute => subclass.to_s.classify)}
        end

        scope :by_subclass, ->(subclass_type) {where(type_attribute => subclass_type.to_s)}
        scope :include_subclass, includes(subclass_types)

        validate :subclass_type_must_be_valid

        before_validation :set_subclass_type, :on => :create
        around_update :update_subclass
      end
    end

    # These methods are available as class level methods to the models that
    # invoke acts_as_base_class, and only to those models.
    module SingletonMethods
    end
    
    # All instances of acts_as_base_class models have access to the following
    # methods.
    module InstanceMethods
      def self.included(base)

        public

          # Returns the subclass association instance. The type column determines the
          # kind of object returned.
          def subclass
            (assoc_name = subclass_assoc_name) ? send(assoc_name) : nil
          end

          # Returns true if the associated subclass row has been read. Note that
          # when creating a new record, this will return false.
          def subclass_loaded?
            (assoc_name = subclass_assoc_name) ? association(assoc_name).loaded? : false
          end

          def abstract_class?
            self.baseclass_options[:abstract]
          end

        private

          # Provides the subclass asociation name, or nil if the type attribute is not set
          def subclass_assoc_name
            if type_name = send(self.type_attribute)
              type_name = type_name.underscore.to_sym
              subclass_types.include?(type_name) ? type_name : nil
            end
          end

          # Called only on new record
          def set_subclass_type
            return if send(type_attribute)
            write_attribute(type_attribute, subclass_types.detect{|s| send(s)}.to_s.classify)
          end

          # Ensure valid subclass type and/or its presence if this is not an abstract base class
          def subclass_type_must_be_valid
            subclass_type = send(type_attribute).try(:underscore)
            subclass_type = nil if subclass_type.blank?

            if abstract_class?
              errors.add(type_attribute, 'Abstract base class requires type attribute') if subclass_type.nil?
              errors.add(:base, 'Abstract base class requires subclass instance') if subclass.nil?
              validate_subclass_type
            else
              return if subclass_type.nil? && subclass.nil?
              errors.add(type_attribute, 'Must provide both subclass type and instance if either is specified') if subclass_type.nil? ^ subclass.nil?
              validate_subclass_type
            end
          end

          def validate_subclass_type
            if subclass_type = send(type_attribute)
              errors.add(type_attribute, "Invalid subclass type: #{subclass_type}") unless subclass_types.include?(subclass_type.underscore.to_sym)
            end
          end

          # This around filter serves two purposes: (1) we ensure to update the
          # subclass when appropriate, and (2) prevent recursion on the updating
          # of this base class.
          def update_subclass
            return true if @updating_base

            begin
              @updating_base = true
              base_save_result = yield

              subclass_save_result = true
              subclass_save_result = save_subclass unless base_save_result == false

              base_save_result && subclass_save_result
            ensure
              @updating_base = false
            end
          end

          # Ensure the associated subclass instance is updated as well (if dirty)
          def save_subclass
            subclass.save if subclass_loaded? && subclass.changed?
          end

        end
    end

    end
  end
end

ActiveRecord::Base.send :include, Bequeath::TableInheritance::BaseClass
