require 'benchmark'

# TODO: I think perhaps I should move all the query building code to a lib of its own.

module DataMapper
  module Adapters
    module Sphinx
      # == Synopsis
      #
      # DataMapper uses URIs or a connection has to connect to your data-stores. In this case the sphinx search daemon
      # <tt>searchd</tt>.
      #
      # On its own this adapter will only return an array of document hashes when queried. The DataMapper library dm-more
      # however provides dm-is-searchable, a common interface to search one adapter and load documents from another. My
      # preference is to use this adapter in tandem with dm-is-searchable.
      #
      # Like all DataMapper adapters you can connect with a Hash or URI.
      #
      # A URI:
      #   DataMapper.setup(:search, 'sphinx://localhost')
      #
      # The breakdown is:
      #   "#{adapter}://#{host}:#{port}/#{config}"
      #   - adapter Must be :sphinx
      #   - host    Hostname (default: localhost)
      #   - port    Optional port number (default: 3312)
      #   - config  Optional but recommended path to sphinx config file.
      #
      # Alternatively supply a Hash:
      #   DataMapper.setup(:search, {
      #     :adapter  => 'sphinx',       # required
      #     :config   => './sphinx.conf' # optional. Recommended though.
      #     :host     => 'localhost',    # optional. Default: localhost
      #     :port     => 3312            # optional. Default: 3312
      #     :managed  => true            # optional. Self managed searchd server using daemon_controller.
      #   })
      class Adapter < AbstractAdapter
        ##
        # Initialize the sphinx adapter.
        #
        # @param [URI, DataObject::URI, Addressable::URI, String, Hash, Pathname] uri_or_options
        # @see   DataMapper::Adapters::Sphinx::Config
        # @see   DataMapper::Adapters::Sphinx::Client
        def initialize(name, uri_or_options)
          super

          managed = !!(uri_or_options.kind_of?(Hash) && uri_or_options[:managed])
          @client  = managed ? ManagedClient.new(uri_or_options) : Client.new(uri_or_options)
        end

        ##
        # Interaction with searchd and indexer.
        #
        # @see DataMapper::Adapters::Sphinx::Client
        # @see DataMapper::Adapters::Sphinx::ManagedClient
        attr_reader :client

        def create(resources) #:nodoc:
          true
        end

        def delete(query) #:nodoc:
          true
        end

        def read_many(query)
          read(query)
        end

        def read_one(query)
          read(query).first
        end

        protected
          ##
          # List sphinx indexes to search.
          # If no indexes are explicitly declared using DataMapper::Adapters::Sphinx::Resource then the default storage
          # name is used.
          #
          # @see DataMapper::Adapters::Sphinx::Resource#sphinx_indexes
          def indexes(model)
            indexes = model.sphinx_indexes(repository(self.name).name) if model.respond_to?(:sphinx_indexes)
            if indexes.nil? or indexes.empty?
              indexes = [Index.new(model, model.storage_name)]
            end
            indexes
          end

          ##
          # List sphinx delta indexes to search.
          #
          # @see DataMapper::Adapters::Sphinx::Resource#sphinx_indexes
          def delta_indexes(model)
            indexes(model).find_all{|i| i.delta?}
          end

          ##
          # Query sphinx for a list of document IDs.
          #
          # @param [DataMapper::Query]
          def read(query)
            from    = indexes(query.model).map{|index| index.name}.join(', ')
            search  = Sphinx::Query.new(query).to_s
            options = {
              :match_mode => :extended, # TODO: Modes!
              :filters    => search_filters(query) # By attribute.
            }
            options[:limit]  = query.limit.to_i  if query.limit
            options[:offset] = query.offset.to_i if query.offset

            if order = search_order(query)
              options.update(
                :sort_mode => :extended,
                :sort_by   => order
              )
            end

            res = @client.search(search, from, options)
            raise res[:error] unless res[:error].nil?

            DataMapper.logger.info(
              %q{Sphinx (%.3f): search '%s' in '%s' found %d documents} % [res[:time], search, from, res[:total]]
            )
            res[:matches].map{|doc| {:id => doc[:doc]}}
          end


          ##
          # Sphinx search query filters from attributes.
          # @param  [DataMapper::Query]
          # @return [Array]
          def search_filters(query)
            filters = []
            query.conditions.each do |operator, attribute, value|
              next unless attribute.kind_of? Sphinx::Attribute
              # TODO: Value cast to uint, bool, str2ordinal, float
              filters << case operator
                when :eql, :like then Riddle::Client::Filter.new(attribute.name.to_s, filter_value(value))
                when :not        then Riddle::Client::Filter.new(attribute.name.to_s, filter_value(value), true)
                else raise NotImplementedError.new("Sphinx: Query attributes do not support the #{operator} operator")
              end
            end
            filters
          end

          ##
          # Order by attributes.
          #
          # @return [String or Symbol]
          def search_order(query)
            by = []
            # TODO: How do you tell the difference between the default query order and someone explicitly asking for
            # sorting by the primary key?
            query.order.each do |order|
              next unless order.property.kind_of? Sphinx::Attribute
              by << [order.property.field, order.direction].join(' ')
            end
            by.empty? ? nil : by.join(', ')
          end

          # TODO: Move this to Attribute#dump.
          # This is ninja'd straight from TS just to get things going.
          def filter_value(value)
            case value
              when Range
                value.first.is_a?(Time) ? value.first.to_i..value.last.to_i : value
              when Array
                value.collect { |val| val.is_a?(Time) ? val.to_i : val }
              else
                Array(value)
            end
          end
      end # Adapter
    end # Sphinx

    # Keep magic in DataMapper#setup happy.
    SphinxAdapter = Sphinx::Adapter
  end # Adapters
end # DataMapper
