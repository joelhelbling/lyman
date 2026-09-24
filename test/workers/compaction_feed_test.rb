require_relative "../test_helper"
require "shifty"
require "lyman"

class CompactionFeedTest < Minitest::Test
  include Shifty::DSL

  def drain(queue)
    items = []
    while (item = queue.pop(timeout: 0))
      items << item
    end
    items
  end

  def test_feeds_each_element_once_as_a_conversation_grows_and_passes_it_through
    first = Lyman::Conversation.new(system_prompt: "sys").with_user_message("hello")
    second = first.with_assistant_message({"role" => "assistant", "content" => "hi"})
    third = second.with_user_message("again")
    inbox = Thread::Queue.new

    pipeline = source_worker([first, second, second, third]) | Lyman::Workers.compaction_feed(inbox)
    results = 4.times.map { pipeline.shift }

    assert_equal [first, second, second, third], results
    assert_equal third.elements, drain(inbox)
    assert(third.elements.all?(&:frozen?), "elements cross threads frozen")
  end

  def test_tracks_each_conversation_separately
    one = Lyman::Conversation.new.with_user_message("one")
    two = Lyman::Conversation.new.with_user_message("two")
    inbox = Thread::Queue.new

    pipeline = source_worker([one, two]) | Lyman::Workers.compaction_feed(inbox)
    2.times { pipeline.shift }

    assert_equal one.elements + two.elements, drain(inbox)
  end
end
