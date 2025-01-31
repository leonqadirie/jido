defmodule Jido.Agent.Server.Signal do
  @moduledoc """
  Defines specialized signals for Agent Server communication and control.

  This module provides functions for creating standardized signals used by the Agent Server.
  There are three main types of signals:

  1. Command Signals (cmd) - Inbound signals that direct Agent behavior
  2. Directive Signals - A specialized subset of command signals for state transitions
  3. Event Signals - Outbound signals that report Agent activity
  """
  use ExDbug, enabled: false

  alias Jido.Signal
  alias Jido.Agent.Types
  alias UUID

  # Signal type prefixes
  @agent_prefix "jido.agent."
  @cmd_prefix "#{@agent_prefix}cmd."
  @directive_prefix "#{@cmd_prefix}directive."
  @event_prefix "#{@agent_prefix}event."

  # Command signal types
  def cmd, do: @cmd_prefix
  def directive, do: @directive_prefix

  # Agent cmd signals
  def cmd_set, do: "#{@cmd_prefix}set"
  def cmd_validate, do: "#{@cmd_prefix}validate"
  def cmd_plan, do: "#{@cmd_prefix}plan"
  def cmd_run, do: "#{@cmd_prefix}run"

  # Event signal types - Command results
  def cmd_failed, do: "#{@event_prefix}cmd.failed"
  def cmd_success, do: "#{@event_prefix}cmd.success"
  def cmd_success_with_syscall, do: "#{@event_prefix}cmd.success.syscall"
  def cmd_success_with_pending_instructions, do: "#{@event_prefix}cmd.success.pending"

  # Event signal types - Process lifecycle
  def process_started, do: "#{@event_prefix}process.started"
  def process_terminated, do: "#{@event_prefix}process.terminated"
  def process_failed, do: "#{@event_prefix}process.failed"

  # Event signal types - Queue processing
  def queue_started, do: "#{@event_prefix}queue.started"
  def queue_completed, do: "#{@event_prefix}queue.completed"
  def queue_failed, do: "#{@event_prefix}queue.failed"
  def queue_overflow, do: "#{@event_prefix}queue.overflow"
  def queue_cleared, do: "#{@event_prefix}queue.cleared"
  def queue_processing_started, do: "#{@event_prefix}queue.processing.started"
  def queue_processing_completed, do: "#{@event_prefix}queue.processing.completed"
  def queue_processing_failed, do: "#{@event_prefix}queue.processing.failed"
  def queue_step_completed, do: "#{@event_prefix}queue.step.completed"
  def queue_step_ignored, do: "#{@event_prefix}queue.step.ignored"
  def queue_step_failed, do: "#{@event_prefix}queue.step.failed"

  # Event signal types - State transitions
  def started, do: "#{@event_prefix}started"
  def stopped, do: "#{@event_prefix}stopped"
  def transition_succeeded, do: "#{@event_prefix}transition.succeeded"
  def transition_failed, do: "#{@event_prefix}transition.failed"

  @doc """
  Creates a signal for setting agent state attributes.
  """
  @spec build_set(%{agent: Types.agent_info()}, map(), Keyword.t()) ::
          {:ok, Signal.t()} | {:error, term()}
  def build_set(%{agent: agent}, attrs, opts \\ []) when is_binary(agent.id) do
    build_base_signal(agent.id, cmd_set(), [{:set, attrs}], %{
      strict_validation: Keyword.get(opts, :strict_validation, false)
    })
  end

  @doc """
  Creates a signal for validating agent state.
  """
  @spec build_validate(%{agent: Types.agent_info()}, Keyword.t()) ::
          {:ok, Signal.t()} | {:error, term()}
  def build_validate(%{agent: agent}, opts \\ []) when is_binary(agent.id) do
    build_base_signal(agent.id, cmd_validate(), [{:validate, %{}}], %{
      strict_validation: Keyword.get(opts, :strict_validation, false)
    })
  end

  @doc """
  Creates a signal for planning agent instructions.
  """
  @spec build_plan(%{agent: Types.agent_info()}, term(), map()) ::
          {:ok, Signal.t()} | {:error, term()}
  def build_plan(%{agent: agent}, instructions, context \\ %{}) when is_binary(agent.id) do
    with {:ok, normalized} <- normalize_instruction(instructions, %{}) do
      build_base_signal(agent.id, cmd_plan(), normalized, %{context: context})
    end
  end

  @doc """
  Creates a signal for running agent instructions.
  """
  @spec build_run(%{agent: Types.agent_info()}, Keyword.t()) ::
          {:ok, Signal.t()} | {:error, term()}
  def build_run(%{agent: agent}, opts \\ []) when is_binary(agent.id) do
    build_base_signal(agent.id, cmd_run(), [{:run, %{}}], %{
      runner: Keyword.get(opts, :runner, nil),
      context: Keyword.get(opts, :context, %{})
    })
  end

  # Private helper to DRY up signal building
  @spec build_base_signal(String.t(), String.t(), list(), map()) ::
          {:ok, Signal.t()} | {:error, term()}
  defp build_base_signal(agent_id, signal_type, instructions, opts) do
    build_signal(signal_type, agent_id, %{},
      jido_instructions: instructions,
      jido_opts: opts
    )
  end

  @doc """
  Creates a command signal with instructions. Returns {:ok, Signal.t()} | {:error, String.t()}.
  """
  @spec build_cmd(%{agent: Types.agent_info()}, term(), map(), Keyword.t()) ::
          {:ok, Signal.t()} | {:error, term()}
  def build_cmd(%{agent: agent}, instruction, params \\ %{}, opts \\ [])
      when is_binary(agent.id) do
    case normalize_instruction(instruction, params) do
      {:ok, instructions} ->
        build_signal(cmd(), agent.id, %{},
          jido_instructions: instructions,
          jido_opts: %{apply_state: Keyword.get(opts, :apply_state, true)}
        )

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Creates a directive signal from a directive struct. Returns {:ok, Signal.t()} | {:error, String.t()}.
  """
  @spec build_directive(%{agent: Types.agent_info()}, struct()) ::
          {:ok, Signal.t()} | {:error, term()}
  def build_directive(%{agent: agent}, %_{} = directive)
      when is_binary(agent.id) and is_struct(directive) do
    build_signal(directive(), agent.id, %{directive: directive})
  end

  def build_directive(%{agent: agent}, _invalid) when is_binary(agent.id) do
    {:error, :invalid_directive}
  end

  @doc """
  Creates an event signal from agent state. Returns {:ok, Signal.t()} | {:error, String.t()}.
  """
  @spec build_event(%{agent: Types.agent_info()}, String.t(), map()) ::
          {:ok, Signal.t()} | {:error, term()}
  def build_event(%{agent: agent}, type, payload \\ %{})
      when is_binary(type) do
    build_signal(type, agent.id, payload)
  end

  @doc """
  Predicates for signal type checking.
  """
  def is_cmd_signal?(%Signal{type: @cmd_prefix <> _}), do: true
  def is_cmd_signal?(_), do: false

  def is_directive_signal?(%Signal{type: @directive_prefix <> _}), do: true
  def is_directive_signal?(_), do: false

  def is_event_signal?(%Signal{type: @event_prefix <> _}), do: true
  def is_event_signal?(_), do: false

  @doc """
  Extracts instructions, data and options from a command signal.
  Returns {:ok, {instructions, data, opts}} | {:error, :invalid_signal_format}
  """
  @spec extract_instructions(Signal.t()) ::
          {:ok, {list(), map(), Keyword.t()}} | {:error, :invalid_signal_format}
  def extract_instructions(%Signal{jido_instructions: instructions, jido_opts: opts, data: data})
      when is_list(instructions) and is_map(opts) do
    {:ok, {instructions, data, Map.to_list(opts)}}
  end

  def extract_instructions(_), do: {:error, :invalid_signal_format}

  # Private Helpers
  defp build_signal(type, subject, data, extra_fields \\ %{})
       when is_binary(type) and is_binary(subject) and
              (is_map(extra_fields) or is_list(extra_fields)) do
    base = %{
      type: type,
      source: "jido://agent/#{subject}",
      subject: subject,
      data: if(is_list(data), do: Map.new(data), else: data),
      id: "#{subject}_#{System.system_time(:nanosecond)}"
    }

    attrs = Map.merge(Map.new(extra_fields), base)

    Signal.new(attrs)
  end

  defp normalize_instruction(instruction, params) when is_atom(instruction) do
    {:ok, [{instruction, params}]}
  end

  defp normalize_instruction({action, params}, _) when is_atom(action) and is_map(params) do
    {:ok, [{action, params}]}
  end

  defp normalize_instruction(instructions, _) when is_list(instructions) do
    if Enum.all?(instructions, &valid_instruction?/1) do
      {:ok, instructions}
    else
      {:error, "invalid instruction format"}
    end
  end

  defp normalize_instruction(_, _), do: {:error, "invalid instruction format"}

  defp valid_instruction?({action, params}) when is_atom(action) and is_map(params), do: true
  defp valid_instruction?(_), do: false
end
