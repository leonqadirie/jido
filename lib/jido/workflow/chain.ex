defmodule Jido.Workflow.Chain do
  @moduledoc """
  Provides functionality to chain multiple Jido Workflows together with interruption support.

  This module allows for sequential execution of workflows, where the output
  of one workflow becomes the input for the next workflow in the chain.
  Execution can be interrupted between workflows using an interruption check function.

  ## Examples

      iex> interrupt_check = fn -> System.monotonic_time(:millisecond) > @deadline end
      iex> Jido.Workflow.Chain.chain([AddOne, MultiplyByTwo], %{value: 5}, interrupt_check: interrupt_check)
      {:ok, %{value: 12}}

      # When interrupted:
      iex> Jido.Workflow.Chain.chain([AddOne, MultiplyByTwo], %{value: 5}, interrupt_check: fn -> true end)
      {:interrupted, %{value: 6}}
  """

  use ExDbug, enabled: false
  require Logger

  alias Jido.Error
  alias Jido.Workflow

  require OK

  @type chain_workflow :: module() | {module(), keyword()}
  @type chain_result :: {:ok, map()} | {:error, Error.t()} | {:interrupted, map()} | Task.t()
  @type interrupt_check :: (-> boolean())

  @doc """
  Executes a chain of workflows sequentially with optional interruption support.

  ## Parameters

  - `workflows`: A list of workflows to be executed in order. Each workflow
    can be a module (the workflow module) or a tuple of `{workflow_module, options}`.
  - `initial_params`: A map of initial parameters to be passed to the first workflow.
  - `opts`: Additional options for the chain execution.

  ## Options

  - `:async` - When set to `true`, the chain will be executed asynchronously (default: `false`).
  - `:context` - A map of context data to be passed to each workflow.
  - `:interrupt_check` - A function that returns boolean, called between workflows to check if chain should be interrupted.

  ## Returns

  - `{:ok, result}` where `result` is the final output of the chain.
  - `{:error, error}` if any workflow in the chain fails.
  - `{:interrupted, result}` if the chain was interrupted, containing the last successful result.
  - `Task.t()` if the `:async` option is set to `true`.
  """
  @spec chain([chain_workflow()], map(), keyword()) :: chain_result()
  def chain(workflows, initial_params \\ %{}, opts \\ []) do
    dbug("Starting chain execution",
      workflows: workflows,
      initial_params: initial_params,
      opts: opts
    )

    async = Keyword.get(opts, :async, false)
    context = Keyword.get(opts, :context, %{})
    interrupt_check = Keyword.get(opts, :interrupt_check)
    opts = Keyword.drop(opts, [:async, :context, :interrupt_check])

    dbug("Chain configuration",
      async: async,
      context: context,
      has_interrupt_check: !is_nil(interrupt_check),
      remaining_opts: opts
    )

    chain_fun = fn ->
      dbug("Entering chain_fun")

      Enum.reduce_while(workflows, {:ok, initial_params}, fn
        workflow, {:ok, params} = _acc ->
          if should_interrupt?(interrupt_check) do
            Logger.info("Chain interrupted before workflow", workflow: workflow)
            {:halt, {:interrupted, params}}
          else
            dbug("Processing workflow",
              workflow: workflow,
              params: params,
              context: context,
              opts: opts
            )

            process_workflow(workflow, params, context, opts)
          end
      end)
    end

    result = if async, do: Task.async(chain_fun), else: chain_fun.()
    dbug("Chain execution completed", result: result)
    result
  end

  @spec should_interrupt?(interrupt_check | nil) :: boolean()
  defp should_interrupt?(nil), do: false
  defp should_interrupt?(check) when is_function(check, 0), do: check.()

  @spec process_workflow(chain_workflow(), map(), map(), keyword()) ::
          {:cont, OK.t()} | {:halt, chain_result()}
  defp process_workflow(workflow, params, context, opts) when is_atom(workflow) do
    dbug("Processing atom workflow", workflow: workflow, params: params)
    run_workflow(workflow, params, context, opts)
  end

  @spec process_workflow({module(), keyword()} | {module(), map()}, map(), map(), keyword()) ::
          {:cont, OK.t()} | {:halt, chain_result()}
  defp process_workflow({workflow, workflow_opts}, params, context, opts)
       when is_atom(workflow) and (is_list(workflow_opts) or is_map(workflow_opts)) do
    dbug("Processing workflow with options",
      workflow: workflow,
      workflow_opts: workflow_opts,
      params: params
    )

    with {:ok, workflow_params} <- validate_workflow_params(workflow_opts) do
      merged_params = Map.merge(params, workflow_params)
      dbug("Merged params", merged_params: merged_params)
      run_workflow(workflow, merged_params, context, opts)
    else
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  @spec process_workflow(any(), map(), map(), keyword()) :: {:halt, {:error, Error.t()}}
  defp process_workflow(invalid_workflow, _params, _context, _opts) do
    dbug("Encountered invalid workflow", invalid_workflow: invalid_workflow)

    {:halt, {:error, Error.bad_request("Invalid chain workflow", %{workflow: invalid_workflow})}}
  end

  @spec validate_workflow_params(keyword() | map()) :: {:ok, map()} | {:error, Error.t()}
  defp validate_workflow_params(opts) when is_list(opts) do
    if Enum.all?(opts, fn {k, _v} -> is_atom(k) end) do
      {:ok, Map.new(opts)}
    else
      {:error, Error.bad_request("Workflow parameters must use atom keys")}
    end
  end

  defp validate_workflow_params(opts) when is_map(opts) do
    if Enum.all?(Map.keys(opts), &is_atom/1) do
      {:ok, opts}
    else
      {:error, Error.bad_request("Workflow parameters must use atom keys")}
    end
  end

  @spec run_workflow(module(), map(), map(), keyword()) ::
          {:cont, OK.t()} | {:halt, chain_result()}
  defp run_workflow(workflow, params, context, opts) do
    dbug("Starting workflow execution",
      workflow: workflow,
      params: params,
      context: context,
      opts: opts
    )

    case Workflow.run(workflow, params, context, opts) do
      OK.success(result) when is_map(result) ->
        dbug("Workflow completed successfully", workflow: workflow, result: result)
        {:cont, OK.success(Map.merge(params, result))}

      OK.success(result) ->
        dbug("Workflow completed successfully with non-map result",
          workflow: workflow,
          result: result
        )

        {:cont, OK.success(Map.put(params, :result, result))}

      OK.failure(error) ->
        Logger.warning("Workflow in chain failed", workflow: workflow, error: error)
        {:halt, OK.failure(error)}
    end
  end
end
