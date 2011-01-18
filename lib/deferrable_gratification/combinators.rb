Dir.glob(File.join(File.dirname(__FILE__), *%w[combinators *.rb])) do |file|
  require file.sub(/\.rb$/, '')
end

module DeferrableGratification
  # Combinators for building up higher-level asynchronous abstractions by
  # composing simpler asynchronous operations, without having to manually wire
  # callbacks together and remember to propagate errors correctly.
  #
  # @example Perform a sequence of database queries and transform the result.
  #   # With DG::Combinators:
  #   def product_names_for_username(username)
  #     DB.query('SELECT id FROM users WHERE username = ?', username).bind! do |user_id|
  #       DB.query('SELECT name FROM products WHERE user_id = ?', user_id)
  #     end.transform do |product_names|
  #       product_names.join(', ')
  #     end
  #   end
  #
  #   status = product_names_for_username('bob')
  #
  #   status.callback {|product_names| ... }
  #   # If both queries complete successfully, the callback receives the string
  #   # "Car, Spoon, Coffee".  The caller doesn't have to know that two separate
  #   # queries were made, or that the query result needed transforming into the
  #   # desired format: he just gets the event he cares about.
  #
  #   status.errback {|error| puts "Oh no!  #{error}" }
  #   # If either query went wrong, the errback receives the error that occurred.
  #
  #
  #   # Without DG::Combinators:
  #   def product_names_for_username(username)
  #     product_names_status = EM::DefaultDeferrable.new
  #     query1_status = DB.query('SELECT id FROM users WHERE username = ?', username)
  #     query1_status.callback do |user_id|
  #       query2_status = DB.query('SELECT name FROM products WHERE user_id = ?', user_id)
  #       query2_status.callback do |product_names|
  #         product_names = product_names.join(', ')
  #         # N.B. don't forget to report success to the caller!
  #         product_names_status.succeed(product_names)
  #       end
  #       query2_status.errback do |error|
  #         # N.B. don't forget to tell the caller we failed!
  #         product_names_status.fail(error)
  #       end
  #     end
  #     query1_status.errback do |error|
  #       # N.B. don't forget to tell the caller we failed!
  #       product_names_status.fail(error)
  #     end
  #     # oh yes, and don't forget to return this!
  #     product_names_status
  #   end

  module Combinators
    # Alias for {#bind!}.
    #
    # Note that this takes a +Proc+ (e.g. a lambda) while {#bind!} takes a
    # block.
    #
    # @param [Proc] prok proc to call with the successful result of +self+.
    #   Assumed to return a Deferrable representing the status of its own
    #   operation.
    #
    # @return [Deferrable] status of the compound operation of passing the
    #     result of +self+ into the proc.
    #
    # @example Perform a database query that depends on the result of a previous query.
    #   DB.query('first query') >> lambda {|result| DB.query("query with #{result}") }
    def >>(prok)
      Bind.setup!(self, &prok)
    end

    # Register callbacks so that when this Deferrable succeeds, its result
    # will be passed to the block, which is assumed to return another
    # Deferrable representing the status of a second operation.
    #
    # If this operation fails, the block will not be run.  If either operation
    # fails, the compound Deferrable returned will fire its errbacks, meaning
    # callers don't have to know about the inner operations and can just
    # subscribe to the result of {#bind!}.
    #
    #
    # If you find yourself writing lots of nested {#bind!} calls, you can
    # equivalently rewrite them as a chain and remove the nesting: e.g.
    #
    #     a.bind! do |x|
    #       b(x).bind! do |y|
    #         c(y).bind! do |z|
    #           d(z)
    #         end
    #       end
    #     end
    #
    # has the same behaviour as
    #
    #     a.bind! do |x|
    #       b(x)
    #     end.bind! do |y|
    #       c(y)
    #     end.bind! do |z|
    #       d(y)
    #     end
    #
    # As well as being more readable due to avoiding left margin inflation,
    # this prevents introducing bugs due to inadvertent local variable capture
    # by the nested blocks.
    #
    #
    # @see #>>
    #
    # @param &block block to call with the successful result of +self+.
    #   Assumed to return a Deferrable representing the status of its own
    #   operation.
    #
    # @return [Deferrable] status of the compound operation of passing the
    #     result of +self+ into the block.
    #
    # @example Perform a web request based on the result of a database query.
    #   DB.query('url').bind! {|url| HTTP.get(url) }.
    #     callback {|response| puts "Got response!" }
    def bind!(&block)
      Bind.setup!(self, &block)
    end

    # Transform the result of this Deferrable by invoking +block+, returning
    # a Deferrable which succeeds with the transformed result.
    #
    # If this operation fails, the operation will not be run, and the returned
    # Deferrable will also fail.
    #
    # @param &block block that transforms the expected result of this
    #   operation in some way.
    #
    # @return [Deferrable] Deferrable that will succeed if this operation did,
    #   after transforming its result.
    #
    # @example Retrieve a web page and call back with its title.
    #   HTTP.request(url).transform {|page| Hpricot(page).at(:title).inner_html }
    def transform(&block)
      bind!(&block)
    end

    # Transform the value passed to the errback of this Deferrable by invoking
    # +block+.  If this operation succeeds, the returned Deferrable will
    # succeed with the same value.  If this operation fails, the returned
    # Deferrable will fail with the transformed error value.
    #
    # @param &block block that transforms the expected error value of this
    #   operation in some way.
    #
    # @return [Deferrable] Deferrable that will succeed if this operation did,
    #   otherwise fail after transforming the error value with which this
    #   operation failed.
    def transform_error(&block)
      errback do |*err|
        self.fail(
          begin
            yield(*err)
          rescue => e
            e
          end)
      end
    end


    # Boilerplate hook to extend {ClassMethods}.
    def self.included(base)
      base.send :extend, ClassMethods
    end

    # Combinators which don't make sense as methods on +Deferrable+.
    #
    # {DeferrableGratification} extends this module, and thus the methods
    # here are accessible via the {DG} alias.
    module ClassMethods
      # Execute a sequence of asynchronous operations that may each depend on
      # the result of the previous operation.
      #
      # @see #bind! more detail on the semantics.
      #
      # @param [*Proc] *actions procs that will perform an operation and
      #   return a Deferrable.
      #
      # @return [Deferrable] Deferrable that will succeed if all of the
      #   chained operations succeeded, and callback with the result of the
      #   last operation.
      def chain(*actions)
        actions.inject(DG.const(nil), &:>>)
      end
    end
  end
end
