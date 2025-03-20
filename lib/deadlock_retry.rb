require 'active_support/core_ext/module/attribute_accessors'

module DeadlockRetry
  mattr_accessor :innodb_status_cmd

  MAXIMUM_RETRIES_ON_DEADLOCK = 3

  def transaction(requires_new: nil, isolation: nil, joinable: true, &block)
    retry_count = 0

    check_innodb_status_available

    begin
      super(requires_new: requires_new, isolation: isolation, joinable: joinable, &block)
    rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked => e
      if in_nested_transaction?
        logger.info { "CDD_DEADLOCK_RETRY_NESTED_TRANSACTION Deadlock detected in a nested transaction, not retrying. [#{e.class}]" }
        raise
      end

      if retry_count >= MAXIMUM_RETRIES_ON_DEADLOCK
        logger.info { "CDD_DEADLOCK_RETRY_MAXIMUM_RETRIES_EXCEEDED Deadlock detected and maximum retries exceeded (maximum: #{MAXIMUM_RETRIES_ON_DEADLOCK}), not retrying. [#{e.class}]" }
        raise
      end

      retry_count += 1
      pause_seconds = exponential_pause_seconds(retry_count)
      logger.info { "CDD_DEADLOCK_RETRY_RETRYING_TRANSACTION Deadlock detected on retry #{retry_count}, retrying transaction in #{pause_seconds} seconds. [#{e.class}]" }
      log_innodb_status if DeadlockRetry.innodb_status_cmd
      sleep_pause(pause_seconds)
      retry
    end
  end

  private

  WAIT_TIMES = [0, 1, 2, 4, 8, 16, 32]

  def exponential_pause_seconds(count)
    # sleep 0, 1, 2, 4, ... seconds up to the MAXIMUM_RETRIES.
    # Cap the pause time at 32 seconds.
    WAIT_TIMES[count-1] || 32
  end

  def sleep_pause(seconds)
    sleep(seconds) if seconds != 0
  end

  def in_nested_transaction?
    # open_transactions was added in 2.2's connection pooling changes.
    connection.open_transactions != 0
  end

  def show_innodb_status
    self.connection.select_all(DeadlockRetry.innodb_status_cmd)
  end

  # Should we try to log innodb status -- if we don't have permission to,
  # we actually break in-flight transactions, silently (!)
  def check_innodb_status_available
    return unless DeadlockRetry.innodb_status_cmd == nil

    if self.connection.adapter_name.match?(/mysql/i)
      begin
        mysql_version = self.connection.select_rows('show variables like \'version\'')[0][1]
        cmd = if mysql_version < '5.5'
          'show innodb status'
        else
          'show engine innodb status'
        end
        self.connection.select_value(cmd)
        DeadlockRetry.innodb_status_cmd = cmd
      rescue
        logger.info { "Cannot log innodb status: #{$!.message}" }
        DeadlockRetry.innodb_status_cmd = false
      end
    else
      DeadlockRetry.innodb_status_cmd = false
    end
  end

  def log_innodb_status
    # show innodb status is the only way to get visiblity into why
    # the transaction deadlocked.  log it.
    lines = show_innodb_status
    logger.warn "INNODB Status follows:"
    logger.warn lines
  rescue => e
    # Access denied, ignore
    logger.info { "Cannot log innodb status: #{e.message}" }
  end
end

ActiveRecord::Base.singleton_class.send(:prepend, DeadlockRetry) if defined?(ActiveRecord)
