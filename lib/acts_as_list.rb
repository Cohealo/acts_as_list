require 'acts_as_list/active_record/acts/list'
require "acts_as_list/active_record/acts/list/disabled"

module ActsAsList
  if defined?(Rails::Railtie)
    class Railtie < Rails::Railtie
      initializer 'acts_as_list.insert_into_active_record' do
        ActiveSupport.on_load :active_record do
          ActiveRecord::Base.send(:include, ActiveRecord::Acts::List)
          ActiveRecord::Base.send(:include, ActiveRecord::Acts::List::Disabled)
        end
      end
    end
  elsif defined?(ActiveRecord)
    ActiveRecord::Base.send(:include, ActiveRecord::Acts::List)
    ActiveRecord::Base.send(:include, ActiveRecord::Acts::List::Disabled)
  end
end
