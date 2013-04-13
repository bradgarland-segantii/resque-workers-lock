require 'resque'

module Resque
  alias_method :orig_remove_queue, :remove_queue

  def remove_queue(queue)
    Resque.redis.keys('workerslock:*').each{ |x| Resque.redis.del(x) }
    orig_remove_queue(queue)
  end

  module Plugins
    module Workers
      module Lock

        # Override in your job to control the worker lock experiation time. This
        # is the time in seconds that the lock should be considered valid. The
        # default is one hour (3600 seconds).
        def worker_lock_timeout(*)
          3600
        end

        # Override in your job to control the workers lock key.
        def lock_workers(*args)
          "#{name}-#{args.to_s}"
        end

        def get_lock_workers(*args)
          "workerslock:"+lock_workers(*args).to_s
        end

        # Override in your job to change the perform requeue delay
        def requeue_perform_delay
          1.0
        end

        # Number of maximum concurrent workers allow
        def concurrent_workers(*args)
          1
        end

        # Called with the job args before perform.
        # If it raises Resque::Job::DontPerform, the job is aborted.
        def before_perform_workers_lock(*args)
          if lock_workers(*args)
            workers_lock = get_lock_workers(*args)
            if Resque.redis.incr(workers_lock) <= concurrent_workers(*args)
              Resque.redis.expire(workers_lock, worker_lock_timeout(*args))
            elsif
              sleep(requeue_perform_delay)
              Resque.enqueue(self, *args)
              raise Resque::Job::DontPerform
            end
          end
        end

        def decr_workers_lock(*args)
          Resque.redis.decr(get_lock_workers(*args))
        end

        def around_perform_workers_lock(*args)
          yield
        ensure
          # Clear the lock. (even with errors)
          decr_workers_lock(*args)
        end

        def on_failure_workers_lock(exception, *args)
          # Clear the lock on DirtyExit
          decr_workers_lock(*args)
        end

      end
    end
  end
end

