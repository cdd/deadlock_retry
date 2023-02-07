FROM ruby:3.1.2

# Speed up install of gems
RUN bundle config jobs 6

WORKDIR /deadlock_retry

COPY Gemfile* *gemspec ./
COPY ./lib/deadlock_retry/version.rb ./lib/deadlock_retry/

RUN bundle

COPY . .
