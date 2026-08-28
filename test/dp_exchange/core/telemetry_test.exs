defmodule DpExchange.Core.TelemetryTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Telemetry

  doctest Telemetry

  describe "event_prefixes/0" do
    test "every event is namespaced under :dp_exchange" do
      # The namespace is what lets a consumer attach one handler across the whole
      # family. An event escaping it is invisible to that handler.
      for prefix <- Telemetry.event_prefixes() do
        assert [:dp_exchange | _rest] = prefix
      end
    end

    test "every event names a category and an event" do
      for prefix <- Telemetry.event_prefixes() do
        assert [:dp_exchange, category, event] = prefix
        assert is_atom(category)
        assert is_atom(event)
      end
    end

    test "the list has no duplicates" do
      prefixes = Telemetry.event_prefixes()
      assert length(prefixes) == length(Enum.uniq(prefixes))
    end

    test "no event category names a transport" do
      # `:ws` named the wire, not the fact. A venue streaming over MQTT has no "ws" to
      # report, so it would emit a lie or emit nothing and look permanently down.
      for [_root, category, _event] <- Telemetry.event_prefixes() do
        refute to_string(category) in ~w(ws websocket socket mqtt http poll sse)
      end
    end

    test "the link lifecycle is present under its own category" do
      prefixes = Telemetry.event_prefixes()

      assert [:dp_exchange, :link, :up] in prefixes
      assert [:dp_exchange, :link, :down] in prefixes
      assert [:dp_exchange, :link, :reconnect_attempt] in prefixes
    end

    test "covers the request lifecycle including the exception path" do
      prefixes = Telemetry.event_prefixes()

      assert [:dp_exchange, :request, :start] in prefixes
      assert [:dp_exchange, :request, :stop] in prefixes
      assert [:dp_exchange, :request, :exception] in prefixes
    end

    test "documents each prefix it lists" do
      # A name emitted but undocumented is a name a consumer cannot discover.
      {:docs_v1, _anno, _lang, _fmt, %{"en" => doc}, _meta, _docs} = Code.fetch_docs(Telemetry)

      for prefix <- Telemetry.event_prefixes() do
        assert doc =~ Enum.map_join(prefix, ", ", &inspect/1)
      end
    end
  end
end
