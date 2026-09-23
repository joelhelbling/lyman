require_relative "../test_helper"
require "shifty"
require "lyman"

class StoreAppendTest < Minitest::Test
  include Shifty::DSL

  def test_persists_every_element_exactly_once_and_passes_conversations_through_unchanged
    store = Lyman::Store.new(":memory:")

    first = Lyman::Conversation.new.with_user_message("hello")
    second = first.with_assistant_message({"role" => "assistant", "content" => "hi there"})
    third = second.with_user_message("and again")

    pipeline = source_worker([first, second, third]) | Lyman::Workers.store_append(store)

    results = [pipeline.shift, pipeline.shift, pipeline.shift]

    assert_equal [first, second, third], results

    stored = store.elements(third.id)
    assert_equal third.elements.map(&:seq), stored.map(&:seq)
    assert_equal third.elements.size, stored.size
  ensure
    store.close
  end

  # No sqlite coupling: store_append only needs #append(conversation), so a
  # fake duck-typed store works exactly the same as Lyman::Store here.
  def test_works_with_a_fake_duck_typed_store
    fake_store = Class.new do
      attr_reader :appended

      def initialize
        @appended = []
      end

      def append(conversation)
        @appended << conversation
        self
      end
    end.new

    convo = Lyman::Conversation.new.with_user_message("hi")
    pipeline = source_worker([convo]) | Lyman::Workers.store_append(fake_store)

    result = pipeline.shift

    assert_equal convo, result
    assert_equal [convo], fake_store.appended
  end
end
