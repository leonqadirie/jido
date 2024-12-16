defmodule JidoTest.WorkflowDoRunTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Jido.Workflow
  alias JidoTest.TestActions.BasicAction
  alias JidoTest.TestActions.ErrorAction
  alias JidoTest.TestActions.RetryAction

  @attempts_table :workflow_do_run_test_attempts

  @attempts_table :workflow_do_run_test_attempts

  setup :set_mimic_global

  setup do
    original_level = Logger.level()
    Logger.configure(level: :debug)

    :ets.new(@attempts_table, [:set, :public, :named_table])
    :ets.insert(@attempts_table, {:attempts, 0})

    on_exit(fn ->
      Logger.configure(level: original_level)

      if :ets.info(@attempts_table) != :undefined do
        :ets.delete(@attempts_table)
      end
    end)

    {:ok, attempts_table: @attempts_table}
  end

  describe "do_run/3" do
    test "executes action with full telemetry" do
      expect(System, :monotonic_time, fn :microsecond -> 0 end)
      expect(:telemetry, :execute, 2, fn _, _, _ -> :ok end)

      log =
        capture_log(fn ->
          assert {:ok, %{value: 5}} =
                   Workflow.do_run(BasicAction, %{value: 5}, %{}, telemetry: :full)
        end)

      assert log =~ "Action Elixir.JidoTest.TestActions.BasicAction start"
      assert log =~ "Action Elixir.JidoTest.TestActions.BasicAction complete"
      verify!()
    end

    test "executes action with minimal telemetry" do
      expect(System, :monotonic_time, fn :microsecond -> 0 end)
      expect(:telemetry, :execute, 2, fn _, _, _ -> :ok end)

      log =
        capture_log(fn ->
          assert {:ok, %{value: 5}} =
                   Workflow.do_run(BasicAction, %{value: 5}, %{}, telemetry: :minimal)
        end)

      assert log =~ "Action Elixir.JidoTest.TestActions.BasicAction start"
      assert log =~ "Action Elixir.JidoTest.TestActions.BasicAction complete"
      verify!()
    end

    test "executes action in silent mode" do
      Mimic.reject(&System.monotonic_time/1)

      log =
        capture_log(fn ->
          assert {:ok, %{value: 5}} =
                   Workflow.do_run(BasicAction, %{value: 5}, %{},
                     telemetry: :silent,
                     timeout: 0
                   )
        end)

      assert log == ""
      verify!()
    end

    test "handles action error" do
      expect(System, :monotonic_time, fn :microsecond -> 0 end)
      expect(:telemetry, :execute, 2, fn _, _, _ -> :ok end)

      log =
        capture_log(fn ->
          assert {:error, _} = Workflow.do_run(ErrorAction, %{}, %{}, telemetry: :full)
        end)

      assert log =~ "Action Elixir.JidoTest.TestActions.ErrorAction start"
      assert log =~ "Action Elixir.JidoTest.TestActions.ErrorAction error"
      verify!()
    end
  end

  describe "get_metadata/4" do
    test "returns full metadata" do
      result = {:ok, %{result: 10}}
      metadata = Workflow.get_metadata(BasicAction, result, 1000, :full)

      assert metadata.action == BasicAction
      assert metadata.result == result
      assert metadata.duration_us == 1000
      assert is_list(metadata.memory_usage)
      assert Keyword.keyword?(metadata.memory_usage)
      assert is_map(metadata.process_info)
      assert is_atom(metadata.node)
    end

    test "returns minimal metadata" do
      result = {:ok, %{result: 10}}
      metadata = Workflow.get_metadata(BasicAction, result, 1000, :minimal)

      assert metadata == %{
               action: BasicAction,
               result: result,
               duration_us: 1000
             }
    end
  end

  describe "get_process_info/0" do
    test "returns process info" do
      info = Workflow.get_process_info()

      assert is_map(info)
      assert Map.has_key?(info, :reductions)
      assert Map.has_key?(info, :message_queue_len)
      assert Map.has_key?(info, :total_heap_size)
      assert Map.has_key?(info, :garbage_collection)
    end
  end

  describe "emit_telemetry_event/3" do
    test "emits telemetry event for full mode" do
      expect(:telemetry, :execute, fn _, _, _ -> :ok end)

      log =
        capture_log(fn ->
          Workflow.emit_telemetry_event(
            :test_event,
            %{action: BasicAction, test: "data"},
            :full
          )
        end)

      assert log =~ "Action Elixir.JidoTest.TestActions.BasicAction test_event"
      verify!()
    end

    test "emits telemetry event for minimal mode" do
      expect(:telemetry, :execute, fn _, _, _ -> :ok end)

      log =
        capture_log(fn ->
          Workflow.emit_telemetry_event(
            :test_event,
            %{action: BasicAction, test: "data"},
            :minimal
          )
        end)

      assert log =~ "Action Elixir.JidoTest.TestActions.BasicAction test_event"
      verify!()
    end

    test "does not emit telemetry event for silent mode" do
      stub(:telemetry, :execute, fn _, _, _ -> :ok end)

      log =
        capture_log(fn ->
          Workflow.emit_telemetry_event(
            :test_event,
            %{action: BasicAction, test: "data"},
            :silent
          )
        end)

      assert log == ""
      verify!()
    end
  end

  describe "do_run_with_retry/4" do
    test "succeeds on first try" do
      expect(System, :monotonic_time, fn :microsecond -> 0 end)
      expect(:telemetry, :execute, 2, fn _, _, _ -> :ok end)

      capture_log(fn ->
        assert {:ok, %{value: 5}} =
                 Workflow.do_run_with_retry(BasicAction, %{value: 5}, %{}, [])
      end)

      verify!()
    end

    test "retries on error and then succeeds", %{attempts_table: attempts_table} do
      expect(System, :monotonic_time, 3, fn :microsecond -> 0 end)
      expect(:telemetry, :execute, 3, fn _, _, _ -> :ok end)

      capture_log(fn ->
        result =
          Workflow.do_run_with_retry(
            RetryAction,
            %{max_attempts: 3, failure_type: :error},
            %{attempts_table: attempts_table},
            max_retries: 2,
            backoff: 10
          )

        assert {:ok, %{result: "success after 3 attempts"}} = result
        assert :ets.lookup(attempts_table, :attempts) == [{:attempts, 3}]
      end)

      verify!()
    end

    test "retries on exception and then succeeds", %{attempts_table: attempts_table} do
      expect(System, :monotonic_time, 3, fn :microsecond -> 0 end)
      expect(:telemetry, :execute, 3, fn _, _, _ -> :ok end)

      capture_log(fn ->
        result =
          Workflow.do_run_with_retry(
            RetryAction,
            %{max_attempts: 3, failure_type: :exception},
            %{attempts_table: attempts_table},
            max_retries: 2,
            backoff: 10
          )

        assert {:ok, %{result: "success after 3 attempts"}} = result
        assert :ets.lookup(attempts_table, :attempts) == [{:attempts, 3}]
      end)

      verify!()
    end

    test "fails after max retries", %{attempts_table: attempts_table} do
      expect(System, :monotonic_time, 3, fn :microsecond -> 0 end)
      expect(:telemetry, :execute, 3, fn _, _, _ -> :ok end)

      capture_log(fn ->
        result =
          Workflow.do_run_with_retry(
            RetryAction,
            %{max_attempts: 5, failure_type: :error},
            %{attempts_table: attempts_table},
            max_retries: 2,
            backoff: 10
          )

        assert {:error, _} = result
        assert :ets.lookup(attempts_table, :attempts) == [{:attempts, 3}]
      end)

      verify!()
    end
  end
end
