defmodule Jido.Chat.Room do
  @moduledoc """
  A chat room that enables agents to exchange messages over a Jido.Bus.

  The room acts as a thin wrapper over the bus, providing a domain-specific
  interface for chat operations while using the bus for all persistence
  and message delivery.
  """
  use GenServer
  alias Jido.Chat.{Message, Participant}

  defmodule State do
    defstruct [
      :bus_name,
      :room_id,
      participants: %{},
      messages: []
    ]
  end

  # Client API

  @doc """
  Returns a via tuple for registering or looking up a room process.

  ## Parameters
    * bus_name - The name of the Jido.Bus
    * room_id - Unique identifier for the room
  """
  def via_tuple(bus_name, room_id) do
    {:via, Registry, {Jido.Chat.Registry, {bus_name, room_id}}}
  end

  @doc """
  Starts a new chat room process.

  ## Options
    * :bus_name - Required. The name of the Jido.Bus to use
    * :room_id - Required. Unique identifier for this room
  """
  def start_link(opts) do
    bus_name = Keyword.fetch!(opts, :bus_name)
    room_id = Keyword.fetch!(opts, :room_id)
    name = via_tuple(bus_name, room_id)
    GenServer.start_link(__MODULE__, {bus_name, room_id}, name: name)
  end

  @doc """
  Adds a participant to the room.

  ## Parameters
    * room - The room process
    * participant - The participant to add
  """
  def add_participant(room, %Participant{} = participant) do
    GenServer.call(room, {:add_participant, participant})
  end

  @doc """
  Removes a participant from the room.

  ## Parameters
    * room - The room process
    * participant_id - The ID of the participant to remove
  """
  def remove_participant(room, participant_id) do
    GenServer.call(room, {:remove_participant, participant_id})
  end

  @doc """
  Lists all participants in the room.
  """
  def list_participants(room) do
    GenServer.call(room, :list_participants)
  end

  @doc """
  Posts a message to the room.

  ## Parameters
    * content - The message content
    * sender_id - The ID of the sender
    * opts - Optional parameters:
      * :type - The message type (:text, :rich, or :system). Defaults to :text
      * :payload - Required for rich messages, the rich content payload
      * :thread_id - Optional thread ID for replies
  """
  def post_message(room, content, sender_id, opts \\ []) do
    GenServer.call(room, {:post_message, content, sender_id, opts})
  end

  @doc """
  Retrieves all messages in the room in chronological order.
  """
  def get_messages(room) do
    GenServer.call(room, :get_messages)
  end

  @doc """
  Retrieves all messages in a thread, including the parent message.
  """
  def get_thread(room, thread_id) do
    GenServer.call(room, {:get_thread, thread_id})
  end

  # Server Callbacks

  @impl true
  def init({bus_name, room_id}) do
    {:ok, %State{bus_name: bus_name, room_id: room_id}}
  end

  @impl true
  def handle_call({:add_participant, participant}, _from, state) do
    case Map.has_key?(state.participants, participant.id) do
      true ->
        {:reply, {:error, :already_joined}, state}

      false ->
        new_state = put_in(state.participants[participant.id], participant)
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:remove_participant, participant_id}, _from, state) do
    case Map.pop(state.participants, participant_id) do
      {nil, _} ->
        {:reply, {:error, :not_found}, state}

      {_participant, new_participants} ->
        {:reply, :ok, %{state | participants: new_participants}}
    end
  end

  @impl true
  def handle_call(:list_participants, _from, state) do
    participants = Map.values(state.participants)
    {:reply, participants, state}
  end

  @impl true
  def handle_call({:post_message, content, sender_id, opts}, _from, state) do
    type = Keyword.get(opts, :type, :text)
    thread_id = Keyword.get(opts, :thread_id)
    payload = Keyword.get(opts, :payload)

    participants_map =
      state.participants
      |> Map.values()
      |> Enum.reduce(%{}, fn p, acc -> Map.put(acc, p.id, Participant.display_name(p)) end)

    attrs = %{
      content: content,
      sender_id: sender_id,
      room_id: state.room_id,
      thread_id: thread_id,
      payload: payload,
      participants: participants_map
    }

    case Message.new(attrs, type) do
      {:ok, message} ->
        new_state = %{state | messages: [message | state.messages]}
        {:reply, {:ok, message}, new_state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:get_messages, _from, state) do
    messages = Enum.reverse(state.messages)
    {:reply, {:ok, messages}, state}
  end

  @impl true
  def handle_call({:get_thread, thread_id}, _from, state) do
    messages =
      state.messages
      |> Enum.filter(&(Message.thread_id(&1) == thread_id))
      |> Enum.reverse()

    case messages do
      [] -> {:reply, {:error, :thread_not_found}, state}
      messages -> {:reply, {:ok, messages}, state}
    end
  end

  # Private Helpers

  # defp publish_message(message, state) do
  #   case Jido.Bus.publish(state.bus_name, state.room_id, :any_version, [message.signal]) do
  #     :ok -> {:reply, {:ok, message}, state}
  #     error -> {:reply, error, state}
  #   end
  # end

  # defp get_messages_from_bus(state) do
  #   case Jido.Bus.replay(state.bus_name, state.room_id) do
  #     {:error, _} = error ->
  #       error

  #     stream ->
  #       messages =
  #         stream
  #         |> Stream.map(&%Message{signal: &1})
  #         |> Enum.to_list()

  #       {:ok, messages}
  #   end
  # end
end
