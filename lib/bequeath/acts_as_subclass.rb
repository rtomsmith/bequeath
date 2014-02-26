# This AR extension lets a model behave as a subclass of a base class table via
# class table inheritance. See acts_as_base_class for documentation.
module Bequeath
  module TableInheritance
    module Subclass   #:nodoc:

    # Invoked when TableInheritance is included in a class
    def self.included(base)
      base.extend ClassMethods
    end

    # Methods accessible at the class declaration level. Keep this to a
    # minimum so the mixin doesn't add any other code unless/until you
    # actually want it.
    module ClassMethods

      def acts_as_subclass(options = {})
        cattr_accessor :cti_base_class              # e.g. Account
        cattr_accessor :base_class_table            # e.g. :accounts
        cattr_accessor :base_class_assoc_name       # e.g. :account

        base_class_name = options[:base_class].to_s.tableize.classify
        self.cti_base_class = base_class_name.constantize
        self.base_class_table = base_class_name.tableize.to_sym
        self.base_class_assoc_name = base_class_table.to_s.singularize.to_sym

        extend  Subclass::SingletonMethods
        include Subclass::InstanceMethods

        belongs_to base_class_assoc_name, :foreign_key => :id, :dependent => :destroy, :autosave => true, :validate => true,
                                          :inverse_of => self.name.underscore.to_sym

        scope :for_subclass_type, joins(base_class_assoc_name).where(base_class_table => {cti_base_class.type_attribute => self.name})
        scope :where_thru_base_class, ->(*args) {for_subclass_type.where(*args)}
        scope :include_base_class, includes(base_class_assoc_name)

        validate :baseclass_present?, :on => :create
        before_validation :set_type_in_baseclass, :on => :create

        define_methods_for_inheritance
        merge_baseclass_whitelist if options[:inherit_whitelist]
      end

      def is_cti_subclass?
        false
      end
    end

    # These methods are available as class level methods to the models that
    # invoke acts_as_subclass, and only to those models.
    module SingletonMethods

      public

        def is_cti_subclass?
          true
        end

      private

        def define_methods_for_inheritance
          define_baseclass_attr_methods     # Generate attribute methods for the base class attributes
          define_baseclass_assoc_methods    # Generate accessor methods for the base class associations
          define_baseclass_methods          # Handlers for declared base class public methods
        end

        # Generate attribute methods for the base class attributes so that they
        # are accessible as if they were attributes of this subclass.
        def define_baseclass_attr_methods
          attribute_names = cti_base_class.attribute_names - self.attribute_names
          attribute_names.each do |attr|
            delegate attr, "#{attr}=", "#{attr}?", :to => :baseclass, :allow_nil => true
            delegate "#{attr}_changed?", "#{attr}_was", "#{attr}_change", "#{attr}_will_change!", :to => :baseclass, :allow_nil => true
          end
        end

        # Generate methods for the base class associations so that they
        # are accessible as if they were associations of this subclass.
        def define_baseclass_assoc_methods
          association_names = cti_base_class.reflect_on_all_associations.collect(&:name) - self.reflect_on_all_associations.collect(&:name)
          association_names.each do |assoc_name|
            assoc = cti_base_class.reflect_on_association(assoc_name)

            delegate assoc_name, "#{assoc_name}=", :to => :baseclass

            if assoc.macro == :belongs_to or assoc.macro == :has_one
              delegate "#{assoc_name}_attributes=", :to => :baseclass
              delegate "build_#{assoc_name}", "create_#{assoc_name}", "create_#{assoc_name}!", :to => :baseclass
            else
              delegate "#{assoc_name.to_s.singularize}_ids", "#{assoc_name.to_s.singularize}_ids=", :to => :baseclass
            end
          end
        end

        # Make methods declared through the +:expose_methods+ option in the base class
        # available to users of this subclass.
        def define_baseclass_methods
          cti_base_class.baseclass_methods.each {|method_name| delegate method_name, :to => :baseclass}
        end

        # Inherit the allowable mass assignment attributes from base class
        def merge_baseclass_whitelist
          attr_accessible *Array(self.cti_base_class.accessible_attributes)
        end

    end

    # All instances of acts_as_subclass models have access to the following
    # methods.
    module InstanceMethods
      def self.included(base)

        public

        # Returns a reference to the base class association. If this is a new record,
        # a base class object is instantiated.
        def baseclass
          baseclass_new if baseclass_undefined?
          send(base_class_assoc_name)
        end

        def changed?(include_baseclass = false)
          return !changed_attributes.empty? if !include_baseclass or baseclass_undefined? or !baseclass_loaded?
          !changed_attributes.empty? or baseclass.changed?
        end

        def changed(include_baseclass = false)
          return changed_attributes.keys if !include_baseclass or baseclass_undefined? or !baseclass_loaded?
          changed_attributes.keys + baseclass.changed
        end

        def changes(include_baseclass = false)
          hsh = changed.inject({}) {|h, attr| h[attr] = self.send("#{attr}_change"); h}
          if include_baseclass
            hsh.merge(baseclass.changed.inject({}) {|h, attr| h[attr] = baseclass.send("#{attr}_change"); h})
          else
            hsh
          end
        end

        protected

          def baseclass_new
            send "#{base_class_assoc_name}=", cti_base_class.new
            set_type_in_baseclass
          end

          def set_type_in_baseclass
            baseclass.send(:write_attribute, cti_base_class.type_attribute, self.class.name)
          end

          def baseclass_loaded?
            association(base_class_assoc_name).loaded?
          end

          def baseclass_present?
            errors.add(base_class_assoc_name, 'cannot be blank on create') if !baseclass_loaded?
          end

          def baseclass_undefined?
            return false unless new_record?
            !baseclass_loaded? or !send(self.base_class_assoc_name)
          end

      end
    end

    end
  end
end

ActiveRecord::Base.send :include, Bequeath::TableInheritance::Subclass
