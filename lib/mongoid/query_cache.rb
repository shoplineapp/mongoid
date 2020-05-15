# encoding: utf-8
module Mongoid

  # A cache of database queries on a per-request basis.
  #
  # @since 4.0.0
  module QueryCache
    class << self

      # Get the cached queries.
      #
      # @example Get the cached queries from the current thread.
      #   QueryCache.cache_table
      #
      # @return [ Hash ] The hash of cached queries.
      #
      # @since 4.0.0
      def cache_table
        Thread.current["[mongoid]:query_cache"] ||= {}
      end

      # Clear the query cache.
      #
      # @example Clear the cache.
      #   QueryCache.clear_cache
      #
      # @return [ nil ] Always nil.
      #
      # @since 4.0.0
      def clear_cache
        Thread.current["[mongoid]:query_cache"] = nil
      end

      # Set whether the cache is enabled.
      #
      # @example Set if the cache is enabled.
      #   QueryCache.enabled = true
      #
      # @param [ true, false ] value The enabled value.
      #
      # @since 4.0.0
      def enabled=(value)
        Thread.current["[mongoid]:query_cache:enabled"] = value
      end

      # Is the query cache enabled on the current thread?
      #
      # @example Is the query cache enabled?
      #   QueryCache.enabled?
      #
      # @return [ true, false ] If the cache is enabled.
      #
      # @since 4.0.0
      def enabled?
        !!Thread.current["[mongoid]:query_cache:enabled"]
      end

      # Execute the block while using the query cache.
      #
      # @example Execute with the cache.
      #   QueryCache.cache { collection.find }
      #
      # @return [ Object ] The result of the block.
      #
      # @since 4.0.0
      def cache
        enabled = QueryCache.enabled?
        QueryCache.enabled = true
        yield
      ensure
        QueryCache.enabled = enabled
      end

      # Execute the block with the query cache disabled.
      #
      # @example Execute without the cache.
      #   QueryCache.uncached { collection.find }
      #
      # @return [ Object ] The result of the block.
      def uncached
        enabled = QueryCache.enabled?
        QueryCache.enabled = false
        yield
      ensure
        QueryCache.enabled = enabled
      end
    end

    # The middleware to be added to a rack application in order to activate the
    # query cache.
    #
    # @since 4.0.0
    class Middleware

      # Instantiate the middleware.
      #
      # @example Create the new middleware.
      #   Middleware.new(app)
      #
      # @param [ Object ] app The rack applciation stack.
      #
      # @since 4.0.0
      def initialize(app)
        @app = app
      end

      # Execute the request, wrapping in a query cache.
      #
      # @example Execute the request.
      #   middleware.call(env)
      #
      # @param [ Object ] env The environment.
      #
      # @return [ Object ] The result of the call.
      #
      # @since 4.0.0
      def call(env)
        QueryCache.cache { @app.call(env) }
      ensure
        QueryCache.clear_cache
      end
    end

    # A Cursor that attempts to load documents from memory first before hitting
    # the database if the same query has already been executed.
    #
    # @since 5.0.0
    class CachedCursor < Mongo::Cursor

      # We iterate over the cached documents if they exist already in the
      # cursor otherwise proceed as normal.
      #
      # @example Iterate over the documents.
      #   cursor.each do |doc|
      #     # ...
      #   end
      #
      # @since 5.0.0
      def each
        if @cached_documents
          @cached_documents.each do |doc|
            yield doc
          end
        else
          super
        end
      end

      # Get a human-readable string representation of +Cursor+.
      #
      # @example Inspect the cursor.
      #   cursor.inspect
      #
      # @return [ String ] A string representation of a +Cursor+ instance.
      #
      # @since 2.0.0
      def inspect
        "#<Mongoid::QueryCache::CachedCursor:0x#{object_id} @view=#{@view.inspect}>"
      end

      # The cache can be iterated again, if the result was completed in one batch
      def iterable_again?
        @batch_count.to_i <= 1
      end

      private

      def process(result)
        documents = super

        @batch_count = @batch_count.to_i + 1
        if @cursor_id.zero? && @batch_count == 1
          @cached_documents = documents
        end

        documents
      end
    end

    # Included to add behaviour for clearing out the query cache on certain
    # operations.
    #
    # @since 4.0.0
    module Base

      def alias_query_cache_clear(*method_names)
        method_names.each do |method_name|
          class_eval <<-CODE, __FILE__, __LINE__ + 1
              def #{method_name}_with_clear_cache(*args)
                QueryCache.clear_cache
                #{method_name}_without_clear_cache(*args)
              end
            CODE

          alias_method "#{method_name}_without_clear_cache", method_name
          alias_method method_name, "#{method_name}_with_clear_cache"
        end
      end
    end

    # Contains enhancements to the Mongo::Collection::View in order to get a
    # cached cursor or a regular cursor on iteration.
    #
    # @since 5.0.0
    module View
      extend ActiveSupport::Concern

      included do
        extend QueryCache::Base
        alias_query_cache_clear :delete_one,
                                :delete_many,
                                :update_one,
                                :update_many,
                                :replace_one,
                                :find_one_and_delete,
                                :find_one_and_replace,
                                :find_one_and_update
      end

      # Override the default enumeration to handle if the cursor can be cached
      # or not.
      #
      # @example Iterate over the view.
      #   view.each do |doc|
      #     # ...
      #   end
      #
      # @since 5.0.0
      def each
        return super unless should_cache?

        @cursor = nil
        @cursor = fetch_cached_cursor do
          session = client.send(:get_session, @options)
          # Expanded implementation of #read_with_retry_cursor
          read_with_retry(session, server_selector) do |server|
            result = send_initial_query(server, session)
            CachedCursor.new(view, result, server, session: session)
          end
        end
        if block_given?
          @cursor.each do |doc|
            yield doc
          end
        else
          @cursor.to_enum
        end
      end

      private

      # Returns a currently cached iterable cursor or yields and caches result
      def fetch_cached_cursor(&block)
        iterable_cached_cursor || cache_cursor(&block)
      end

      # Returns iterable cursor or nil
      # Tries to fetch a cursor without limit first, if a limit is currently set
      def iterable_cached_cursor
        if limit
          iterable_cached_cursor_for_limit(nil) ||
            iterable_cached_cursor_for_limit(limit)
        else
          iterable_cached_cursor_for_limit(limit)
        end
      end

      # Returns iterable cursor or nil for given limit
      def iterable_cached_cursor_for_limit(limit)
        cursor = QueryCache.cache_table[cache_key(limit: limit)]
        cursor&.iterable_again? ? cursor : nil
      end

      def cache_key(limit:)
        [ collection.namespace, selector, limit, skip, sort, projection, collation ]
      end

      # Caches the result of block
      def cache_cursor(&block)
        QueryCache.cache_table[cache_key(limit: limit)] = yield
      end

      def should_cache?
        QueryCache.enabled? && !system_collection?
      end

      def system_collection?
        collection.namespace =~ /\Asystem./
      end
    end

    # Adds behaviour to the query cache for collections.
    #
    # @since 5.0.0
    module Collection
      extend ActiveSupport::Concern

      included do
        extend QueryCache::Base
        alias_query_cache_clear :insert_one, :insert_many
      end
    end

    # Bypass the query cache when reloading a document.
    module Document
      def reload
        QueryCache.uncached { super }
      end
    end
  end
end

Mongo::Collection.__send__(:include, Mongoid::QueryCache::Collection)
Mongo::Collection::View.__send__(:include, Mongoid::QueryCache::View)
Mongoid::Document.__send__(:include, Mongoid::QueryCache::Document)
