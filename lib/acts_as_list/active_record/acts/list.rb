module ActiveRecord
  module Acts #:nodoc:
    module List #:nodoc:
      def self.included(base)
        base.extend(ClassMethods)
      end

      # This +acts_as+ extension provides the capabilities for sorting and reordering a number of objects in a list.
      # The class that has this specified needs to have a +position+ column defined as an integer on
      # the mapped database table.
      #
      # Todo list example:
      #
      #   class TodoList < ActiveRecord::Base
      #     has_many :todo_items, order: "position"
      #   end
      #
      #   class TodoItem < ActiveRecord::Base
      #     belongs_to :todo_list
      #     acts_as_list scope: :todo_list
      #   end
      #
      #   todo_list.first.move_to_bottom
      #   todo_list.last.move_higher
      module ClassMethods
        # Configuration options are:
        #
        # * +column+ - specifies the column name to use for keeping the position integer (default: +position+)
        # * +scope+ - restricts what is to be considered a list. Given a symbol, it'll attach <tt>_id</tt>
        #   (if it hasn't already been added) and use that as the foreign key restriction. It's also possible
        #   to give it an entire string that is interpolated if you need a tighter scope than just a foreign key.
        #   Example: <tt>acts_as_list scope: 'todo_list_id = #{todo_list_id} AND completed = 0'</tt>
        # * +top_of_list+ - defines the integer used for the top of the list. Defaults to 1. Use 0 to make the collection
        #   act more like an array in its indexing.
        # * +add_new_at+ - specifies whether objects get added to the :top or :bottom of the list. (default: +bottom+)
        #                   `nil` will result in new items not being added to the list on create
        def acts_as_list(options = {})
          configuration = { column: "position", scope: "1 = 1", top_of_list: 1, add_new_at: :bottom}
          configuration.update(options) if options.is_a?(Hash)

          configuration[:scope] = "#{configuration[:scope]}_id".intern if configuration[:scope].is_a?(Symbol) && configuration[:scope].to_s !~ /_id$/

          if configuration[:scope].is_a?(Symbol)
            scope_methods = %(
              def scope_condition
                { :#{configuration[:scope].to_s} => send(:#{configuration[:scope].to_s}) }
              end

              def scope_changed?
                changes.include?(scope_name.to_s)
              end
            )
          elsif configuration[:scope].is_a?(Array)
            scope_methods = %(
              def attrs
                %w(#{configuration[:scope].join(" ")}).inject({}) do |memo,column|
                  memo[column.intern] = read_attribute(column.intern); memo
                end
              end

              def scope_changed?
                (attrs.keys & changes.keys.map(&:to_sym)).any?
              end

              def scope_condition
                attrs
              end
            )
          else
            scope_methods = %(
              def scope_condition
                "#{configuration[:scope]}"
              end

              def scope_changed?() false end
            )
          end

          class_eval <<-EOV
            include ::ActiveRecord::Acts::List::InstanceMethods

            def acts_as_list_top
              #{configuration[:top_of_list]}.to_i
            end

            def acts_as_list_class
              ::#{self.name}
            end

            def position_column
              '#{configuration[:column]}'
            end

            def scope_name
              '#{configuration[:scope]}'
            end

            def add_new_at
              '#{configuration[:add_new_at]}'
            end

            def #{configuration[:column]}=(position)
              write_attribute(:#{configuration[:column]}, position)
              @position_changed = true
            end

            #{scope_methods}

            # only add to attr_accessible
            # if the class has some mass_assignment_protection

            if defined?(accessible_attributes) and !accessible_attributes.blank?
              attr_accessible :#{configuration[:column]}
            end

            before_destroy :reload_position
            after_destroy :decrement_positions_on_lower_items
            before_update :check_scope
            after_update :update_positions
            before_validation :check_top_position

            scope :in_list, lambda { where("#{table_name}.#{configuration[:column]} IS NOT NULL") }
          EOV

          if configuration[:add_new_at].present?
            self.send(:before_create, "add_to_list_#{configuration[:add_new_at]}")
          end

        end
      end

      # All the methods available to a record that has had <tt>acts_as_list</tt> specified. Each method works
      # by assuming the object to be the item in the list, so <tt>chapter.move_lower</tt> would move that chapter
      # lower in the list of all chapters. Likewise, <tt>chapter.first?</tt> would return +true+ if that chapter is
      # the first in the list of all chapters.
      module InstanceMethods
        # Insert the item at the given position (defaults to the top position of 1).
        def insert_at(position = acts_as_list_top)
          insert_at_position(position)
        end

        # Swap positions with the next lower item, if one exists.
        def move_lower
          return unless lower_item

          acts_as_list_class.transaction do
            lower_item.decrement_position
            increment_position
          end
        end

        # Swap positions with the next higher item, if one exists.
        def move_higher
          return unless higher_item

          acts_as_list_class.transaction do
            higher_item.increment_position
            decrement_position
          end
        end

        # Move to the bottom of the list. If the item is already in the list, the items below it have their
        # position adjusted accordingly.
        def move_to_bottom
          return unless in_list?
          acts_as_list_class.transaction do
            decrement_positions_on_lower_items
            assume_bottom_position
          end
        end

        # Move to the top of the list. If the item is already in the list, the items above it have their
        # position adjusted accordingly.
        def move_to_top
          return unless in_list?
          acts_as_list_class.transaction do
            increment_positions_on_higher_items
            assume_top_position
          end
        end

        # Removes the item from the list.
        def remove_from_list
          if in_list?
            decrement_positions_on_lower_items
            set_list_position(nil)
          end
        end

        # Move the item within scope. If a position within the new scope isn't supplied, the item will
        # be appended to the end of the list.
        def move_within_scope(scope_id)
          send("#{scope_name}=", scope_id)
          save!
        end

        # Increase the position of this item without adjusting the rest of the list.
        def increment_position
          return unless in_list?
          set_list_position(self.send(position_column).to_i + 1)
        end

        # Decrease the position of this item without adjusting the rest of the list.
        def decrement_position
          return unless in_list?
          set_list_position(self.send(position_column).to_i - 1)
        end

        # Return +true+ if this object is the first in the list.
        def first?
          return false unless in_list?
          self.send(position_column) == acts_as_list_top
        end

        # Return +true+ if this object is the last in the list.
        def last?
          return false unless in_list?
          self.send(position_column) == bottom_position_in_list
        end

        # Return the next higher item in the list.
        def higher_item
          return nil unless in_list?
          higher_items(1).first
        end

        # Return the next n higher items in the list
        # selects all higher items by default
        def higher_items(limit=nil)
          limit ||= acts_as_list_list.count
          position_value = send(position_column)
          acts_as_list_list.
            where("#{position_column} < ?", position_value).
            where("#{position_column} >= ?", position_value - limit).
            limit(limit).
            order("#{acts_as_list_class.table_name}.#{position_column} ASC")
        end

        # Return the next lower item in the list.
        def lower_item
          return nil unless in_list?
          lower_items(1).first
        end

        # Return the next n lower items in the list
        # selects all lower items by default
        def lower_items(limit=nil)
          limit ||= acts_as_list_list.count
          position_value = send(position_column)
          acts_as_list_list.
            where("#{position_column} > ?", position_value).
            where("#{position_column} <= ?", position_value + limit).
            limit(limit).
            order("#{acts_as_list_class.table_name}.#{position_column} ASC")
        end

        # Test if this record is in a list
        def in_list?
          !not_in_list?
        end

        def not_in_list?
          send(position_column).nil?
        end

        def default_position
          acts_as_list_class.columns_hash[position_column.to_s].default
        end

        def default_position?
          default_position && default_position.to_i == send(position_column)
        end

        # Sets the new position and saves it
        def set_list_position(new_position)
          write_attribute position_column, new_position
          save(validate: false)
        end

        private
          def acts_as_list_list
            acts_as_list_class.unscoped do
              acts_as_list_class.where(scope_condition)
            end
          end

          def add_to_list_top
            return unless act_as_list_run_callbacks?
            increment_positions_on_all_items
            self[position_column] = acts_as_list_top
          end

          def add_to_list_bottom
            return unless act_as_list_run_callbacks?
            if not_in_list? || scope_changed? && !@position_changed || default_position?
              self[position_column] = bottom_position_in_list.to_i + 1
            else
              increment_positions_on_lower_items(self[position_column], id)
            end
          end

          # Overwrite this method to define the scope of the list changes
          def scope_condition() {} end

          # Returns the bottom position number in the list.
          #   bottom_position_in_list    # => 2
          def bottom_position_in_list(except = nil)
            item = bottom_item(except)
            item ? item.send(position_column) : acts_as_list_top - 1
          end

          # Returns the bottom item
          def bottom_item(except = nil)
            conditions = scope_condition
            conditions = except ? "#{self.class.primary_key} != #{self.class.connection.quote(except.id)}" : {}
            acts_as_list_list.in_list.where(
              conditions
            ).order(
              "#{acts_as_list_class.table_name}.#{position_column} DESC"
            ).first
          end

          # Forces item to assume the bottom position in the list.
          def assume_bottom_position
            set_list_position(bottom_position_in_list(self).to_i + 1)
          end

          # Forces item to assume the top position in the list.
          def assume_top_position
            set_list_position(acts_as_list_top)
          end

          # This has the effect of moving all the higher items up one.
          def decrement_positions_on_higher_items(position)
            acts_as_list_list.where(
              "#{position_column} <= #{position}"
            ).update_all(
              "#{position_column} = (#{position_column} - 1)"
            )
          end

          # This has the effect of moving all the lower items up one.
          def decrement_positions_on_lower_items(position=nil)
            return unless in_list? && act_as_list_run_callbacks?
            position ||= send(position_column).to_i
            acts_as_list_list.where(
              "#{position_column} > #{position}"
            ).update_all(
              "#{position_column} = (#{position_column} - 1)"
            )
          end

          # This has the effect of moving all the higher items down one.
          def increment_positions_on_higher_items
            return unless in_list?
            acts_as_list_list.where(
              "#{position_column} < #{send(position_column).to_i}"
            ).update_all(
              "#{position_column} = (#{position_column} + 1)"
            )
          end

          # This has the effect of moving all the lower items down one.
          def increment_positions_on_lower_items(position, avoid_id = nil)
            avoid_id_condition = avoid_id ? " AND #{self.class.primary_key} != #{self.class.connection.quote(avoid_id)}" : ''

            acts_as_list_list.where(
              "#{position_column} >= #{position}#{avoid_id_condition}"
            ).update_all(
              "#{position_column} = (#{position_column} + 1)"
            )
          end

          # Increments position (<tt>position_column</tt>) of all items in the list.
          def increment_positions_on_all_items
            acts_as_list_list.update_all(
              "#{position_column} = (#{position_column} + 1)"
            )
          end

          # Reorders intermediate items to support moving an item from old_position to new_position.
          def shuffle_positions_on_intermediate_items(old_position, new_position, avoid_id = nil)
            return if old_position == new_position
            avoid_id_condition = avoid_id ? " AND #{self.class.primary_key} != #{self.class.connection.quote(avoid_id)}" : ''

            if old_position < new_position
              # Decrement position of intermediate items
              #
              # e.g., if moving an item from 2 to 5,
              # move [3, 4, 5] to [2, 3, 4]
              acts_as_list_list.where(
                "#{position_column} > #{old_position}"
              ).where(
                "#{position_column} <= #{new_position}#{avoid_id_condition}"
              ).update_all(
                "#{position_column} = (#{position_column} - 1)"
              )
            else
              # Increment position of intermediate items
              #
              # e.g., if moving an item from 5 to 2,
              # move [2, 3, 4] to [3, 4, 5]
              acts_as_list_list.where(
                "#{position_column} >= #{new_position}"
              ).where(
                "#{position_column} < #{old_position}#{avoid_id_condition}"
              ).update_all(
                "#{position_column} = (#{position_column} + 1)"
              )
            end
          end

          def insert_at_position(position)
            return set_list_position(position) if new_record?
            if in_list?
              old_position = send(position_column).to_i
              return if position == old_position
              shuffle_positions_on_intermediate_items(old_position, position)
            else
              increment_positions_on_lower_items(position)
            end
            set_list_position(position)
          end

          # used by insert_at_position instead of remove_from_list, as postgresql raises error if position_column has non-null constraint
          def store_at_0
            if in_list?
              old_position = send(position_column).to_i
              set_list_position(0)
              decrement_positions_on_lower_items(old_position)
            end
          end

          def update_positions
            return unless act_as_list_run_callbacks?

            old_position = send("#{position_column}_was").to_i
            new_position = send(position_column).to_i

            return unless acts_as_list_list.where(
              "#{position_column} = #{new_position}"
            ).count > 1
            shuffle_positions_on_intermediate_items old_position, new_position, id
          end

          # Temporarily swap changes attributes with current attributes
          def swap_changed_attributes
            @changed_attributes.each do |k, _|
              if self.class.column_names.include? k
                @changed_attributes[k], self[k] = self[k], @changed_attributes[k]
              end
            end
          end

          def check_scope
            return unless act_as_list_run_callbacks?
            if scope_changed?
              swap_changed_attributes
              send('decrement_positions_on_lower_items') if lower_item
              swap_changed_attributes
              send("add_to_list_#{add_new_at}")
            end
          end

          def reload_position
            return unless act_as_list_run_callbacks?
            self.reload
          end

          # This check is skipped if the position is currently the default position from the table
          # as modifying the default position on creation is handled elsewhere
          def check_top_position
            return unless act_as_list_run_callbacks?
            if send(position_column) && !default_position? && send(position_column) < acts_as_list_top
              self[position_column] = acts_as_list_top
            end
          end
      end
    end
  end
end
