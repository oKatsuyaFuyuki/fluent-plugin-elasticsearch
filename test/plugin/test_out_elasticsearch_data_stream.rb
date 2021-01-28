require_relative '../helper'
require 'date'
require 'fluent/test/helpers'
require 'fluent/test/driver/output'
require 'flexmock/test_unit'
require 'fluent/plugin/out_elasticsearch_data_stream'

class ElasticsearchOutputDataStreamTest < Test::Unit::TestCase
  include FlexMock::TestCase
  include Fluent::Test::Helpers

  attr_accessor :bulk_records

  REQUIRED_ELASTIC_MESSAGE = "Elasticsearch 7.9.0 or later is needed."
  ELASTIC_DATA_STREAM_TYPE = "elasticsearch_data_stream"

  def setup
    Fluent::Test.setup
    @driver = nil
    log = Fluent::Engine.log
    log.out.logs.slice!(0, log.out.logs.length)
  end

  def driver(conf='', es_version=5, client_version="\"5.0\"")
    # For request stub to detect compatibility.
    @es_version ||= es_version
    @client_version ||= client_version
    Fluent::Plugin::ElasticsearchOutputDataStream.module_eval(<<-CODE)
      def detect_es_major_version
        #{@es_version}
      end
    CODE
    @driver ||= Fluent::Test::Driver::Output.new(Fluent::Plugin::ElasticsearchOutputDataStream) {
      # v0.12's test driver assume format definition. This simulates ObjectBufferedOutput format
      if !defined?(Fluent::Plugin::Output)
        def format(tag, time, record)
          [time, record].to_msgpack
        end
      end
    }.configure(conf)
  end

  def sample_data_stream
    {
      'data_streams': [
                        {
                          'name' => 'my-data-stream',
                          'timestamp_field' => {
                            'name' => '@timestamp'
                          }
                        }
                      ]
    }
  end

  def sample_record
    {'@timestamp' => Time.now.iso8601, 'message' => 'Sample record'}
  end

  RESPONSE_ACKNOWLEDGED = {"acknowledged": true}
  DUPLICATED_DATA_STREAM_EXCEPTION = {"error": {}, "status": 400}
  NONEXISTENT_DATA_STREAM_EXCEPTION = {"error": {}, "status": 404}

  def stub_ilm_policy(url="http://localhost:9200/_ilm/policy/foo_policy")
    stub_request(:put, url).to_return(:status => [200, RESPONSE_ACKNOWLEDGED])
  end

  def stub_index_template(url="http://localhost:9200/_index_template/foo")
    stub_request(:put, url).to_return(:status => [200, RESPONSE_ACKNOWLEDGED])
  end

  def stub_data_stream(url="http://localhost:9200/_data_stream/foo")
    stub_request(:put, url).to_return(:status => [200, RESPONSE_ACKNOWLEDGED])
  end

  def stub_existent_data_stream?(url="http://localhost:9200/_data_stream/foo")
    stub_request(:get, url).to_return(:status => [200, RESPONSE_ACKNOWLEDGED])
  end

  def stub_nonexistent_data_stream?(url="http://localhost:9200/_data_stream/foo")
    stub_request(:get, url).to_return(:status => [200, Elasticsearch::Transport::Transport::Errors::NotFound])
  end

  def stub_bulk_feed(url="http://localhost:9200/foo/_bulk")
    stub_request(:post, url).with do |req|
      # bulk data must be pair of OP and records
      # {"create": {}}\n
      # {"@timestamp": ...}
      @bulk_records = req.body.split("\n").size / 2
    end
  end

  def stub_default
    stub_ilm_policy
    stub_index_template
    stub_existent_data_stream?
    stub_data_stream
  end

  def data_stream_supported?
    Gem::Version.create(::Elasticsearch::Transport::VERSION) >= Gem::Version.create("7.9.0")
  end

  # ref. https://www.elastic.co/guide/en/elasticsearch/reference/master/indices-create-data-stream.html
  class DataStreamNameTest < self

    def test_missing_data_stream_name
      conf = config_element(
        'ROOT', '', {
          '@type' => 'elasticsearch_datastream'
        })
      assert_raise Fluent::ConfigError.new("'data_stream_name' parameter is required") do
        driver(conf).run
      end
    end

    def test_invalid_uppercase
      conf = config_element(
        'ROOT', '', {
          '@type' => 'elasticsearch_datastream',
          'data_stream_name' => 'TEST'
        })
      assert_raise Fluent::ConfigError.new("'data_stream_name' must be lowercase only: <TEST>") do
        driver(conf)
      end
    end

    data("backslash" => "\\",
         "slash" => "/",
         "asterisk" => "*",
         "question" => "?",
         "doublequote" => "\"",
         "lt" => "<",
         "gt" => ">",
         "bar" => "|",
         "space" => " ",
         "comma" => ",",
         "sharp" => "#",
         "colon" => ":")
    def test_invalid_characters(data)
      c, _ = data
      conf = config_element(
        'ROOT', '', {
          '@type' => ELASTIC_DATA_STREAM_TYPE,
          'data_stream_name' => "TEST#{c}"
        })
      label = Fluent::Plugin::ElasticsearchOutputDataStream::INVALID_CHARACTERS.join(',')
      assert_raise Fluent::ConfigError.new("'data_stream_name' must not contain invalid characters #{label}: <TEST#{c}>") do
        driver(conf)
      end
    end

    data("hyphen" => "-",
         "underscore" => "_",
         "plus" => "+",
         "period" => ".")
    def test_invalid_start_characters(data)
      c, _ = data
      conf = config_element(
        'ROOT', '', {
          '@type' => ELASTIC_DATA_STREAM_TYPE,
          'data_stream_name' => "#{c}TEST"
        })
      label = Fluent::Plugin::ElasticsearchOutputDataStream::INVALID_START_CHRACTERS.join(',')
      assert_raise Fluent::ConfigError.new("'data_stream_name' must not start with #{label}: <#{c}TEST>") do
        driver(conf)
      end
    end

    data("current" => ".",
         "parents" => "..")
    def test_invalid_dots
      c, _ = data
      conf = config_element(
        'ROOT', '', {
          '@type' => ELASTIC_DATA_STREAM_TYPE,
          'data_stream_name' => "#{c}"
        })
      assert_raise Fluent::ConfigError.new("'data_stream_name' must not be . or ..: <#{c}>") do
        driver(conf)
      end
    end

    def test_invalid_length
      c = "a" * 256
      conf = config_element(
        'ROOT', '', {
          '@type' => ELASTIC_DATA_STREAM_TYPE,
          'data_stream_name' => "#{c}"
        })
      assert_raise Fluent::ConfigError.new("'data_stream_name' must not be longer than 255 bytes: <#{c}>") do
        driver(conf)
      end
    end
  end

  def test_datastream_configure
    omit REQUIRED_ELASTIC_MESSAGE unless data_stream_supported?

    stub_default
    conf = config_element(
      'ROOT', '', {
        '@type' => ELASTIC_DATA_STREAM_TYPE,
        'data_stream_name' => 'foo'
      })
    assert_equal "foo", driver(conf).instance.data_stream_name
  end

  def test_nonexistent_data_stream
    omit REQUIRED_ELASTIC_MESSAGE unless data_stream_supported?

    stub_ilm_policy
    stub_index_template
    stub_nonexistent_data_stream?
    stub_data_stream
    conf = config_element(
      'ROOT', '', {
        '@type' => ELASTIC_DATA_STREAM_TYPE,
        'data_stream_name' => 'foo'
      })
    assert_equal "foo", driver(conf).instance.data_stream_name
  end

  def test_bulk_insert_feed
    omit REQUIRED_ELASTIC_MESSAGE unless data_stream_supported?

    stub_default
    stub_bulk_feed
    conf = config_element(
      'ROOT', '', {
        '@type' => ELASTIC_DATA_STREAM_TYPE,
        'data_stream_name' => 'foo'
      })
    driver(conf).run(default_tag: 'test') do
      driver.feed(sample_record)
    end
    assert_equal 1, @bulk_records
  end
end