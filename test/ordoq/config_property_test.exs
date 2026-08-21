defmodule Ordoq.ConfigPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Ordoq.Config

  property "validated numerical settings retain every configured bound" do
    check all(
            minimum <- integer(0..20),
            priority_offset <- integer(0..20),
            maximum_offset <- integer(0..20),
            ttr_ms <- integer(1..10_000),
            ttr_extra_ms <- integer(0..10_000),
            retry_base_ms <- integer(0..5_000),
            retry_extra_ms <- integer(0..5_000)
          ) do
      default_priority = minimum + priority_offset
      maximum = default_priority + maximum_offset
      max_ttr_ms = ttr_ms + ttr_extra_ms
      max_retry_delay_ms = retry_base_ms + retry_extra_ms

      assert {:ok, config} =
               Config.new(
                 min_priority: minimum,
                 default_priority: default_priority,
                 max_priority: maximum,
                 default_ttr_ms: ttr_ms,
                 max_ttr_ms: max_ttr_ms,
                 default_retry_base_ms: retry_base_ms,
                 max_retry_delay_ms: max_retry_delay_ms,
                 retry_jitter_ms: retry_extra_ms
               )

      assert Config.min_priority(config) == minimum
      assert Config.default_priority(config) == default_priority
      assert Config.max_priority(config) == maximum
      assert Config.default_ttr_ms(config) == ttr_ms
      assert Config.max_ttr_ms(config) == max_ttr_ms
      assert Config.default_retry_base_ms(config) == retry_base_ms
      assert Config.max_retry_delay_ms(config) == max_retry_delay_ms
    end
  end
end
