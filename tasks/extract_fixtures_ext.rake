# Redmine - project management software
# Copyright (C) 2006-  Jean-Philippe Lang
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

desc 'Create YAML test fixtures from data in an existing database.
Defaults to development database. Set RAILS_ENV to override.'

module Psych
  module Visitors
    class YAMLTree
      # Override default time format
      # https://github.com/ruby/ruby/blob/v3_3_6/ext/psych/lib/psych/visitors/yaml_tree.rb#L484-L490
      def format_time time, utc = time.utc?
        if utc
          time.strftime("%Y-%m-%d %H:%M:%S")
        else
          time.strftime("%Y-%m-%d %H:%M:%S %:z")
        end
      end
    end
  end
end

task :extract_fixtures_ext => :environment do
  dir = ENV['DIR'] || './tmp/fixtures'
  time_offset = ENV['TIME_OFFSET'] || ''
  tables = ENV['TABLES']&.split(',') || []
  skip_tables = ENV['SKIP_TABLES']&.split(',') || []
  table_filters = ENV['TABLE_FILTERS']&.split(';')&.map {|tf| tf.split(":", 2)}&.to_h || {}
  omit_default_or_nil = ActiveRecord::Type::Boolean.new.cast(ENV.fetch('OMIT_DEFAULT_OR_NIL', 'false'))

  FileUtils.mkdir_p(dir)
  if time_offset.present? && !time_offset.match?(/^([+-](0[0-9]|1[0-4]):[0-5][0-9])$/)
    abort("Invalid TIME_OFFSET format. Use +HH:MM or -HH:MM (e.g. +09:00)")
  end
  skip_tables += ["schema_migrations", "ar_internal_metadata"]

  ActiveRecord::Base.establish_connection
  tables = tables.present? ? tables : ActiveRecord::Base.connection.tables
  (tables - skip_tables).each do |table_name|
    columns = ActiveRecord::Base.connection.columns(table_name)
    column_names = columns.map(&:name)
    has_id_column = column_names.include?('id')
    order_columns = has_id_column ? 'id' : column_names.join(', ')
    where_clause = table_filters.has_key?(table_name) ? "WHERE #{table_filters[table_name]}" : ''
    sql = "SELECT * FROM #{table_name} #{where_clause} ORDER BY #{order_columns}"
    data = ActiveRecord::Base.connection.select_all(sql)
    if data.empty?
      next
    end
    i = "000"
    File.open(File.join(dir, "#{table_name}.yml"), 'w') do |file|
      file.write data.inject({}) { |hash, record|
        # omit default or nil values or cast extracted values with formatting time
        columns.each do |col|
          if omit_default_or_nil && (
            (!col.default.nil? && !record[col.name].nil? && record[col.name].to_s == col.default) ||
            (col.default.nil? && record[col.name].nil?)
          )
            record.delete(col.name)
            next
          elsif record[col.name]
            record[col.name] = ActiveRecord::Type.lookup(col.type).deserialize(record[col.name])
            if col.type == :datetime && record[col.name].is_a?(Time)
              if time_offset.present?
                record[col.name] = record[col.name].localtime(time_offset)
              else
                record[col.name] = record[col.name].getutc
              end
            elsif col.type == :binary
              utf8text = record[col.name].dup.force_encoding('UTF-8')
              if utf8text.valid_encoding?
                record[col.name] = utf8text
              end
            end
          end
        end
        key_id = has_id_column ? sprintf('%03d', record['id']) : i.succ!
        hash["#{table_name}_#{key_id}"] = record
        hash
      }.to_yaml
    end
  end
end
