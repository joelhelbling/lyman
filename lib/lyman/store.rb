require "sqlite3"
require "json"

module Lyman
  # A persistent, indexed conversation store: SQLite, confined to this one
  # file (dependency isolation — nothing else in lyman knows sqlite3
  # exists). Durability is an optional splice, not a built-in assumption:
  # a harness that never needs to recall or compact just never wires this
  # in, and pays nothing for it. See docs/design/context-control.md
  # ("Store and recall").
  #
  # The schema mirrors the Conversation/Element shape directly: a
  # conversations row per conversation (with its lineage pointer) and an
  # elements row per Element, plus an FTS5 index for text recall.
  class Store
    def initialize(path)
      @db = SQLite3::Database.new(path.to_s)
      @db.results_as_hash = true
      create_schema
    end

    def close
      @db.close
    end

    # Idempotent: elements are immutable and append-only, so inserting only
    # what's past the highest stored seq makes calling this many times with
    # the same (or a grown) conversation exact rather than approximate. A
    # side worker spliced into the circuit sees every round, including ones
    # it has already stored.
    def append(conversation)
      @db.transaction do
        @db.execute(
          "INSERT OR IGNORE INTO conversations (id, parent_id) VALUES (?, ?)",
          [conversation.id, conversation.parent_id]
        )

        max_seq = @db.get_first_value(
          "SELECT MAX(seq) FROM elements WHERE conversation_id = ?", [conversation.id]
        ) || 0

        conversation.elements.select { |e| e.seq > max_seq }.each do |element|
          content_json = JSON.generate(element.content)
          @db.execute(
            "INSERT INTO elements (conversation_id, seq, type, content) VALUES (?, ?, ?, ?)",
            [element.conversation_id, element.seq, element.type, content_json]
          )
          @db.execute(
            "INSERT INTO element_text (conversation_id, seq, text) VALUES (?, ?, ?)",
            [element.conversation_id, element.seq, searchable_text(element)]
          )
        end
      end

      self
    end

    def conversation(id)
      @db.get_first_row("SELECT id, parent_id, created_at FROM conversations WHERE id = ?", [id])
    end

    # Accepts any Range Conversation#elements_in does — bounded, endless
    # (2..), beginless (..5), inclusive or exclusive — so the stored and
    # in-memory views of a series answer the same questions the same way.
    def elements(conversation_id, range = nil)
      sql = "SELECT * FROM elements WHERE conversation_id = ?"
      binds = [conversation_id]
      if range&.begin
        sql += " AND seq >= ?"
        binds << range.begin
      end
      if range&.end
        sql += range.exclude_end? ? " AND seq < ?" : " AND seq <= ?"
        binds << range.end
      end
      @db.execute("#{sql} ORDER BY seq", binds).map { |row| to_element(row) }
    end

    def element(conversation_id, seq)
      row = @db.get_first_row(
        "SELECT * FROM elements WHERE conversation_id = ? AND seq = ?", [conversation_id, seq]
      )
      row && to_element(row)
    end

    # Addresses round-trip with Element#address: "conv:ID" (all elements),
    # "conv:ID#17" (one), "conv:ID#17-23" (a range). ID is anything up to
    # the '#' — UUIDs in practice, but tests use simple ids too.
    def fetch(address)
      match = /\Aconv:([^#]+)(?:#(\d+)(?:-(\d+))?)?\z/.match(address.to_s)
      raise ArgumentError, "malformed address #{address.inspect}" unless match

      conversation_id, from, to = match.captures
      if from.nil?
        elements(conversation_id)
      elsif to.nil?
        found = element(conversation_id, from.to_i)
        found ? [found] : []
      else
        elements(conversation_id, from.to_i..to.to_i)
      end
    end

    # Plain-word search: query is treated as words, not FTS syntax, so
    # punctuation like "what's the time?" can't raise. (Each quoted token
    # still runs through FTS5's tokenizer, so "what's" matches as the
    # phrase "what s".) Each token is
    # quoted (with embedded quotes doubled) and the tokens are ANDed —
    # FTS5's implicit behavior for adjacent quoted strings.
    def search(query, conversation_id: nil, limit: 20)
      tokens = query.to_s.split(/\s+/).reject(&:empty?)
      return [] if tokens.empty?

      match = tokens.map { |t| "\"#{t.gsub('"', '""')}\"" }.join(" ")

      binds = [match]
      scope = ""
      if conversation_id
        ids = lineage(conversation_id)
        return [] if ids.empty?
        scope = "AND element_text.conversation_id IN (#{ids.map { "?" }.join(", ")})"
        binds.concat(ids)
      end

      rows = @db.execute(<<~SQL, [*binds, limit])
        SELECT elements.* FROM element_text
        JOIN elements ON elements.conversation_id = element_text.conversation_id
                     AND elements.seq = element_text.seq
        WHERE element_text MATCH ? #{scope}
        ORDER BY bm25(element_text) LIMIT ?
      SQL

      rows.map { |row| to_element(row) }
    end

    # Ancestor chain starting with conversation_id itself, then parent,
    # grandparent... UNION (not UNION ALL) guards against a cyclic
    # parent_id chain looping forever.
    def lineage(conversation_id)
      return [] unless conversation(conversation_id)

      rows = @db.execute(<<~SQL, [conversation_id])
        WITH RECURSIVE chain(id, parent_id) AS (
          SELECT id, parent_id FROM conversations WHERE id = ?
          UNION
          SELECT c.id, c.parent_id FROM conversations c
          JOIN chain ON c.id = chain.parent_id
        )
        SELECT id FROM chain
      SQL
      rows.map { |row| row["id"] }
    end

    # Only the series and its lineage are durable; rounds and finished are
    # a turn's transient control state, so a loaded conversation starts
    # fresh — ready for a new user message, not resumable mid-turn.
    def load(conversation_id)
      row = conversation(conversation_id)
      return nil unless row

      Lyman::Conversation.new(
        id: row["id"],
        parent_id: row["parent_id"],
        elements: elements(conversation_id)
      )
    end

    private

    # No foreign key from elements/conversations.parent_id to conversations.id:
    # a parent may be compacted and stored elsewhere, or not yet stored at
    # all when this conversation is appended. Lineage is a pointer a query
    # walks (see #lineage), not a constraint the database enforces.
    def create_schema
      @db.execute_batch(<<~SQL)
        CREATE TABLE IF NOT EXISTS conversations (
          id TEXT PRIMARY KEY,
          parent_id TEXT,
          created_at TEXT DEFAULT CURRENT_TIMESTAMP
        );

        CREATE TABLE IF NOT EXISTS elements (
          conversation_id TEXT NOT NULL,
          seq INTEGER NOT NULL,
          type TEXT NOT NULL,
          content TEXT NOT NULL,
          PRIMARY KEY (conversation_id, seq)
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS element_text USING fts5(
          conversation_id UNINDEXED,
          seq UNINDEXED,
          text
        );
      SQL
    end

    def to_element(row)
      Lyman::Element.new(
        conversation_id: row["conversation_id"],
        seq: row["seq"],
        type: row["type"],
        content: JSON.parse(row["content"])
      )
    end

    def searchable_text(element)
      case element.type
      when "system", "user", "reasoning", "assistant"
        element.content["text"].to_s
      when "tool_call"
        name = element.content.dig("function", "name")
        arguments = element.content.dig("function", "arguments")
        arguments = JSON.generate(arguments) if arguments.is_a?(Hash)
        "#{name} #{arguments}"
      when "tool_result"
        element.content["text"].to_s
      end
    end
  end
end
