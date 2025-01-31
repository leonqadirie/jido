defmodule Jido.Agent.Server.Execute do
  @moduledoc false
  # Handles execution of signals in the agent server.

  # This module is responsible for:
  # - Processing incoming signals by enqueuing them
  # - Managing the signal queue and execution flow
  # - Handling signal execution results and state transitions
  # - Emitting events for signal processing lifecycle

  use Private
  use ExDbug, enabled: true

  alias Jido.Agent.Server.State, as: ServerState
  alias Jido.Agent.Server.Signal, as: ServerSignal
  alias Jido.Agent.Server.Output, as: ServerOutput
  alias Jido.Signal

  @type signal_result ::
          {:ok, ServerState.t()}
          | {:ignore, term()}
          | {:error, term()}

  @doc """
  Processes a signal by enqueuing it and starting queue processing.

  ## Parameters
    - state: The current ServerState struct containing agent state and signal queue
    - signal: The Signal struct to be processed

  ## Returns
    - `{:ok, state}` - Signal processed successfully with updated state
    - `{:error, reason}` - Signal processing failed

  ## Examples

      iex> state = %ServerState{...}
      iex> signal = %Signal{type: :action, data: %{...}}
      iex> {:ok, new_state} = Execute.process_signal(state, signal)

  """
  @spec process_signal(ServerState.t(), Signal.t()) ::
          {:ok, ServerState.t()}
          | {:error, term()}
  def process_signal(%ServerState{} = state, %Signal{} = signal) do
    case ServerState.enqueue(state, signal) do
      {:ok, new_state} ->
        process_signal_queue(new_state)

      {:error, reason} ->
        {:error, reason}
    end
  end

  private do
    # Processes the signal queue by executing signals one at a time until the queue is empty.
    #
    # Emits events for queue processing start, completion, and failure states.
    #
    # ## Parameters
    #   - state: The current ServerState struct containing the signal queue
    #
    # ## Returns
    #   - `{:ok, state}` - Queue processed successfully with updated state
    #   - `{:error, reason}` - Queue processing failed
    #
    # ## Events Emitted
    #   - queue_processing_started - When queue processing begins
    #   - queue_processing_completed - When all signals processed successfully
    #   - queue_processing_failed - If queue processing fails
    defp process_signal_queue(%ServerState{} = state) do
      ServerOutput.emit_event(state, ServerSignal.queue_processing_started(), %{
        queue_size: :queue.len(state.pending_signals)
      })

      case process_queue_signals(state) do
        {:ok, final_state} ->
          ServerOutput.emit_event(final_state, ServerSignal.queue_processing_completed(), %{})
          {:ok, final_state}

        {:error, reason} = error ->
          ServerOutput.emit_event(state, ServerSignal.queue_processing_failed(), %{reason: reason})

          error
      end
    end

    # Recursively processes signals in the queue until empty.
    #
    # For each signal:
    # 1. Dequeues the next signal
    # 2. Executes it via execute_signal/2
    # 3. Emits appropriate events based on execution result
    # 4. Continues processing remaining signals
    #
    # ## Parameters
    #   - state: The current ServerState struct containing the signal queue
    #
    # ## Returns
    #   - `{:ok, state}` - All signals processed successfully
    #   - `{:error, reason}` - Signal processing failed
    #
    # ## Events Emitted
    #   - queue_step_completed - When a signal executes successfully
    #   - queue_step_ignored - When a signal is ignored
    #   - queue_step_failed - When a signal fails to execute
    defp process_queue_signals(%ServerState{} = state) do
      dbug("Processing queue signals", queue_size: :queue.len(state.pending_signals))

      case ServerState.dequeue(state) do
        {:ok, signal, new_state} ->
          case execute_signal(new_state, signal) do
            {:ok, updated_state} ->
              ServerOutput.emit_event(updated_state, ServerSignal.queue_step_completed(), %{
                completed_signal: signal
              })

              process_queue_signals(updated_state)

            {:ignore, reason} ->
              ServerOutput.emit_event(new_state, ServerSignal.queue_step_ignored(), %{
                ignored_signal: signal,
                reason: reason
              })

              process_queue_signals(new_state)

            {:error, reason} = error ->
              ServerOutput.emit_event(new_state, ServerSignal.queue_step_failed(), %{
                failed_signal: signal,
                reason: reason
              })

              error
          end

        {:error, :empty_queue} ->
          {:ok, state}
      end
    end

    # Executes a signal based on its type.
    #
    # This function handles the core signal execution logic by:
    # 1. Determining the signal type (command or directive)
    # 2. Routing to the appropriate execution handler
    # 3. Providing error handling via try/rescue
    #
    # ## Parameters
    #   - state: The current ServerState struct
    #   - signal: The Signal struct to execute
    #
    # ## Returns
    #   - `{:ok, state}` - Signal executed successfully with updated state
    #   - `{:ignore, reason}` - Signal was ignored (e.g. unknown type)
    #   - `{:error, reason}` - Signal execution failed
    #
    # ## Examples
    #     iex> execute_signal(state, agent_signal)
    #     {:ok, updated_state}
    #
    #     iex> execute_signal(state, unknown_signal)
    #     {:ignore, {:unknown_signal_type, :unknown}}
    @spec execute_signal(ServerState.t(), Signal.t()) :: signal_result()
    defp execute_signal(%ServerState{} = state, %Signal{} = signal) do
      try do
        cond do
          ServerSignal.is_cmd_signal?(signal) ->
            execute_agent_signal(state, signal)

          ServerSignal.is_directive_signal?(signal) ->
            execute_directive_signal(state, signal)

          true ->
            {:ignore, {:unknown_signal_type, signal.type}}
        end
      rescue
        error ->
          dbug("Signal execution failed", error: Exception.format(:error, error, __STACKTRACE__))
          {:error, {:signal_execution_failed, error}}
      end
    end

    # Executes a directive signal.
    #
    # This function handles directive signal execution by:
    # 1. Extracting the directive from the signal
    # 2. Executing the directive with the current state
    # 3. Handling any errors that occur during execution
    #
    # ## Parameters
    #   - state: The current ServerState struct
    #   - signal: The Signal struct containing the directive
    #
    # ## Returns
    #   - `{:ok, state}` - Successfully executed the directive
    #   - `{:error, reason}` - Directive execution failed
    @spec execute_directive_signal(ServerState.t(), Signal.t()) :: signal_result()
    defp execute_directive_signal(%ServerState{} = state, %Signal{data: %{directive: directive}}) do
      with {:ok, state} <- ensure_running_state(state),
           {:ok, agent_result, directives} <-
             state.agent.__struct__.cmd(state.agent, directive, %{}, []),
           {:ok, state} <- handle_agent_result(state, agent_result),
           {:ok, idle_state} <- ServerState.transition(state, :idle) do
        dbug("Directive signal executed successfully")
        {:ok, idle_state, directives}
      end
    end

    defp execute_directive_signal(_state, _signal) do
      {:error, :invalid_directive_format}
    end

    # Executes an agent signal based on the server's current state.
    #
    # This function handles agent signal execution with state transitions:
    #
    # - When server is paused: Queues the signal for later processing
    # - When server is idle/running: Executes the signal with proper state transitions
    # - When server is in any other state: Returns an invalid state error
    #
    # ## Parameters
    #   - state: The current ServerState struct
    #   - signal: The Signal struct to execute
    #
    # ## Returns
    #   - `{:ok, state}` - Successfully executed or queued the signal
    #   - `{:error, {:invalid_state, status}}` - Server was in invalid state
    #
    # ## State Transitions
    #   - :paused -> No transition, signal is queued
    #   - :idle/:running -> Transitions to :running, executes signal, returns to :idle
    #   - other -> Returns error
    @spec execute_agent_signal(ServerState.t(), Signal.t()) :: signal_result()
    defp execute_agent_signal(%ServerState{status: :paused} = state, signal) do
      dbug("Agent paused, queueing signal", signal: signal)
      ServerState.enqueue(state, signal)
    end

    defp execute_agent_signal(%ServerState{status: status} = state, %Signal{} = signal)
         when status in [:idle, :running] do
      dbug("Executing agent signal in #{status} state", signal: signal)

      with {:ok, state} <- ensure_running_state(state),
           {:ok, agent_result, _directives} <- agent_signal_cmd(state, signal),
           {:ok, state} <- handle_agent_result(state, agent_result),
           {:ok, idle_state} <- ServerState.transition(state, :idle) do
        dbug("Agent signal executed successfully")
        {:ok, idle_state}
      end
    end

    defp execute_agent_signal(%ServerState{status: status}, _signal) do
      dbug("Invalid state for agent signal execution", status: status)
      {:error, {:invalid_state, status}}
    end

    # Executes an agent command signal when the server is in the running state.
    #
    # This function handles the execution of agent commands by:
    # 1. Extracting the instructions and options from the signal
    # 2. Calling the agent's cmd/4 function with the extracted values
    # 3. Handling any errors that occur during execution
    #
    # ## Parameters
    #   - state: The current ServerState struct, must be in :running status
    #   - signal: The Signal struct containing the command to execute
    #
    # ## Returns
    #   - `{:ok, result}` - Successfully executed the command
    #   - `{:error, error}` - An error occurred during execution
    #   - `{:error, {:invalid_state, status}}` - Server was in invalid state
    @spec agent_signal_cmd(ServerState.t(), Signal.t()) :: {:ok, map()} | {:error, term()}
    defp agent_signal_cmd(%ServerState{status: :running} = state, %Signal{} = signal) do
      case ServerSignal.extract_instructions(signal) do
        {:ok, {instructions, data, opts}} ->
          dbug("Executing agent command", instructions: instructions, data: data, opts: opts)

          try do
            state.agent.__struct__.cmd(state.agent, instructions, data, opts)
          rescue
            error ->
              dbug("Action execution failed",
                instructions: instructions,
                error: Exception.format(:error, error, __STACKTRACE__)
              )

              {:error, error}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp agent_signal_cmd(%ServerState{status: status}, %Signal{}) do
      dbug("Invalid state for agent command", status: status)
      {:error, {:invalid_state, status}}
    end

    # Handles the result of an agent action execution.
    #
    # This function processes the result of an agent action based on its content and state.
    # It handles several cases in priority order:
    #
    # 1. Error results - If the result contains an error, returns the error
    # 2. Pending instructions - If the agent has pending instructions, processes them via handle_pending_instructions/2
    # 3. Other results - Updates the server state with the new agent state
    #
    # ## Parameters
    #   - state: The current ServerState struct
    #   - agent_result: The result map from the agent action containing:
    #     - result: The actual result data
    #     - error: Optional error information
    #     - pending_instructions: Queue of pending instructions
    #
    # ## Returns
    #   - `{:ok, state}` - Successfully processed result and updated state
    #   - `{:error, reason}` - An error occurred during processing
    @spec handle_agent_result(ServerState.t(), map()) ::
            {:ok, ServerState.t()}
            | {:error, term()}
    defp handle_agent_result(%ServerState{} = state, %{result: result} = agent_result) do
      dbug("Handling agent result", result: result)

      cond do
        # Check if result map has error key
        match?(%{error: error} when not is_nil(error), result) ->
          error = result.error
          ServerOutput.emit_event(state, ServerSignal.cmd_failed(), %{result: result})
          dbug("Action resulted in error", error: error)
          {:error, error}

        # Check if agent has pending instructions
        not :queue.is_empty(agent_result.pending_instructions) ->
          dbug("Agent has pending instructions",
            pending: :queue.len(agent_result.pending_instructions)
          )

          ServerOutput.emit_event(state, ServerSignal.cmd_success_with_pending_instructions(), %{
            result: result
          })

          handle_pending_instructions(state, agent_result)

        # Handle other results
        true ->
          dbug("Handling other result", result: result)
          ServerOutput.emit_event(state, ServerSignal.cmd_success(), %{result: result})
          {:ok, %{state | agent: agent_result}}
      end
    end

    # Processes pending instructions from an agent by converting them to signals.
    #
    # This function takes pending instructions from the agent's queue, converts each one into a signal,
    # and adds those signals to the server state's pending signals queue. After successful conversion,
    # it clears the agent's pending instruction queue.
    #
    # ## Parameters
    #   - state: The current ServerState struct
    #   - agent_result: The agent struct containing pending instructions to process
    #
    # ## Returns
    #   - `{:ok, state}` - Successfully converted all instructions to signals and cleared queue
    #   - `{:error, reason}` - Failed to convert an instruction or enqueue a signal
    #
    # ## Process
    # 1. Converts instruction queue to list
    # 2. For each instruction:
    #    - Creates an action signal with the instruction's action, params and opts
    #    - Enqueues the signal in the server state
    # 3. On success, clears the agent's pending instruction queue
    # 4. On any error, halts processing and returns the error
    defp handle_pending_instructions(%ServerState{} = state, agent_result) do
      dbug("Handling pending instructions",
        pending: :queue.len(agent_result.pending_instructions)
      )

      # Convert pending instructions to signals and add to state queue
      new_state =
        agent_result.pending_instructions
        |> :queue.to_list()
        |> Enum.reduce_while({:ok, %{state | agent: agent_result}}, fn instruction,
                                                                       {:ok, acc_state} ->
          case ServerSignal.build_cmd(
                 acc_state,
                 {instruction.action, instruction.params},
                 %{},
                 apply_state: true
               ) do
            {:ok, signal} ->
              case ServerState.enqueue(acc_state, signal) do
                {:ok, updated_state} -> {:cont, {:ok, updated_state}}
                {:error, reason} -> {:halt, {:error, reason}}
              end

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)

      # Clear pending instructions from agent after converting to signals
      case new_state do
        {:ok, updated_state} ->
          {:ok,
           %{updated_state | agent: %{updated_state.agent | pending_instructions: :queue.new()}}}

        error ->
          error
      end
    end

    # Ensures the server is in a running state by transitioning from idle if needed.
    #
    # This function handles three cases:
    # - When idle: Transitions to running state
    # - When already running: Returns current state unchanged
    # - When in any other state: Returns an error
    #
    # ## Parameters
    #   - state: The current ServerState struct
    #
    # ## Returns
    #   - `{:ok, state}` - Successfully transitioned to or already in running state
    #   - `{:error, {:invalid_state, status}}` - Cannot transition from current status
    defp ensure_running_state(%ServerState{status: :idle} = state) do
      dbug("Transitioning from idle to running state")

      with {:ok, running_state} <- ServerState.transition(state, :running) do
        {:ok, running_state}
      end
    end

    defp ensure_running_state(%ServerState{status: :running} = state) do
      dbug("State already running")
      {:ok, state}
    end

    defp ensure_running_state(%ServerState{status: status}) do
      dbug("Cannot transition to running state", current_status: status)
      {:error, {:invalid_state, status}}
    end
  end
end
