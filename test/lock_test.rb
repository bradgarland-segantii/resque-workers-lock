require 'test/unit'
require File.expand_path('../../lib/resque/plugins/workers/lock', __FILE__)
require 'tempfile'
require 'timeout'

require_relative 'unique_job'

class LockTest < Test::Unit::TestCase
  

  def setup
    Resque.redis.del(UniqueJob.get_lock_workers)
  end

  def test_lint
    assert_nothing_raised do
      Resque::Plugin.lint(Resque::Plugins::Workers::Lock)
    end
  end

  def test_workers_dont_work_simultaneously
    assert_locking_works_with jobs: 2, workers: 2, max_workers: 1
  end

  def test_two_workers_work_simultaneously
    assert_locking_works_with jobs: 3, workers: 3, max_workers: 2
  end

  def test_worker_locks_timeout
    output_file = Tempfile.new 'output_file'

    Resque.enqueue UniqueJob, job: 'interrupted-job', output_file: output_file.path, sleep: 1000

    worker_pid = start_worker
    wait_until(10){ lock_has_been_acquired }
    kill_worker(worker_pid)

    Resque.enqueue UniqueJob, job: 'completing-job', output_file: output_file.path, sleep: 0
    process_jobs workers: 1, timeout: UniqueJob.worker_lock_timeout + 2

    lines = File.readlines(output_file).map(&:chomp)
    assert_equal ['starting interrupted-job', 'starting completing-job', 'finished completing-job'], lines
  end

  def test_remove_stale_lock
    output_file = Tempfile.new 'output_file'
    Resque.redis.incr(UniqueJob.get_lock_workers)
    Resque.enqueue UniqueJob, job: 'new-job', output_file: output_file.path
    process_jobs workers: 1, timeout: UniqueJob.worker_lock_timeout + 3, sleep: 0
    lines = File.readlines(output_file).map(&:chomp)
    assert_equal ['starting new-job', 'finished new-job'], lines
  end

  private

  def lock_has_been_acquired
    Resque.redis.exists(UniqueJob.get_lock_workers)
  end

  def kill_worker(worker_pid)
    Process.kill("TERM", worker_pid)
    Process.waitpid(worker_pid)
  end

  def start_worker
    fork.tap do |pid|
      if !pid
        worker = Resque::Worker.new('*')
        worker.term_child = true
        worker.reconnect
        worker.work(0.5)
        exit!
      end
    end
  end

  def assert_worker_lock_exists(job_class, *args)
    assert Resque.redis.exists(job_class.get_lock_workers(*args), "lock does not exist")
  end

  def assert_locking_works_with options
    jobs = (1..options[:jobs]).map{|job| "Job #{job}" }
    output_file = Tempfile.new 'output_file'

    jobs.each do |job|
      Resque.enqueue UniqueJob, job: job, output_file: output_file.path, max_workers: options[:max_workers]
    end

    process_jobs workers: options[:workers], timeout: options[:timeout] || 5

    lines = File.readlines(output_file).map(&:chomp)
    lines.each_slice(options[:max_workers] + 1) do |jobs|
      job_ids = jobs.map {|j| j[/([0-9]+)/, 1]}
      assert_equal job_ids.uniq.size, options[:max_workers], "#{jobs} are executed concurrently"
    end
  end

  def process_jobs options
    with_workers options[:workers] do
      wait_until(options[:timeout]) do
         no_busy_workers && no_queued_jobs
      end
    end
  end

  def with_workers n
    pids = []
    n.times do
      if pid = fork
        pids << pid
      else
        pids = [] # Don't kill from child's ensure
        worker = Resque::Worker.new('*')
        worker.term_child = true
        worker.reconnect
        worker.work(0.5)
        exit!
      end
    end

    yield

  ensure
    pids.each do |pid|
      Process.kill("QUIT", pid)
    end

    pids.each do |pid|
      Process.waitpid(pid)
    end
  end

  def no_busy_workers
    Resque::Worker.working.size == 0
  end

  def no_queued_jobs
    Resque.redis.llen("queue:lock_test") == 0
  end

  def wait_until(timeout)
    Timeout::timeout(timeout) do
      loop do
        return if yield
        sleep 1
      end
    end
  end
end
