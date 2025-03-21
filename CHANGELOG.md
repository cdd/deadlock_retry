deadlock_retry changes

== v2.2.2

* Retry on ActiveRecord::Deadlocked, in addition to ActiveRecord::LockWaitTimeout

== v2.1.0

* update for rails 5 keyword args

== v2.0.3

* tweak the show_innodb_status code

== v2.0.1

* Use ActiveRecord::LockWaitTimeout
* Update mysql connection check
* Revert support to set the log level for retries

== v2.0.0

* Rearchitect to take advantage of ruby 2.0.  Should also work for ruby 3.
* Add support to set the log level for retries

== v1.2.0

* Support for postgres (tomhughes)
* Testing AR versions (kbrock)

== v1.1.2

* Exponential backoff, sleep 0, 1, 2, 4... seconds between retries.
* Support new syntax for InnoDB status in MySQL 5.5.

== v1.1.1 (2011-05-13)

* Conditionally log INNODB STATUS only if user has permission. (osheroff)

== v1.1.0 (2011-04-20)

* Modernize.
* Drop support for Rails 2.1 and earlier.

== v1.0 - (2009-02-07)

* Add INNODB status logging for debugging deadlock issues.
* Clean up so the code will run as a gem plugin.
* Small fix for ActiveRecord 2.1.x compatibility.
