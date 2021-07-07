source 'https://rubygems.org'
gemspec

gem 'jruby-openssl', :platforms => :jruby
# gem 'digital_river', git: 'git@github.com:/chargify/digital_river.git', ref: "v4"
gem 'digital_river', git: 'git@github.com:/chargify/digital_river.git', ref: "PGT-1141-raw-gateway-logging-support"

group :test, :remote_test do
  # gateway-specific dependencies, keeping these gems out of the gemspec
  gem 'braintree', '>= 2.50.0'
end
