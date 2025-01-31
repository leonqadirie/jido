defmodule Jido.Chat.SupervisorTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.Supervisor

  setup do
    bus_name = "test_bus_#{System.unique_integer()}"
    start_supervised!(Supervisor)
    {:ok, bus_name: bus_name}
  end

  test "start_room/2 starts a new room", %{bus_name: bus_name} do
    {:ok, pid} = Supervisor.start_room(bus_name, "test_room")
    assert is_pid(pid)
  end

  test "start_room/2 returns existing room if already started", %{bus_name: bus_name} do
    {:ok, pid1} = Supervisor.start_room(bus_name, "test_room")
    {:ok, pid2} = Supervisor.start_room(bus_name, "test_room")
    assert pid1 == pid2
  end

  test "start_room/2 can start multiple rooms", %{bus_name: bus_name} do
    {:ok, pid1} = Supervisor.start_room(bus_name, "room1")
    {:ok, pid2} = Supervisor.start_room(bus_name, "room2")
    assert pid1 != pid2
  end

  test "get_room/2 returns error for non-existent room", %{bus_name: bus_name} do
    assert {:error, :not_found} = Supervisor.get_room(bus_name, "non_existent")
  end

  test "list_rooms/1 returns all rooms for a bus", %{bus_name: bus_name} do
    {:ok, _pid1} = Supervisor.start_room(bus_name, "room1")
    {:ok, _pid2} = Supervisor.start_room(bus_name, "room2")

    rooms = Supervisor.list_rooms(bus_name)
    assert length(rooms) == 2
    assert Enum.member?(rooms, "room1")
    assert Enum.member?(rooms, "room2")
  end

  test "list_rooms/1 returns empty list when no rooms exist", %{bus_name: bus_name} do
    assert Supervisor.list_rooms(bus_name) == []
  end

  test "stop_room/2 stops a running room", %{bus_name: bus_name} do
    {:ok, _pid} = Supervisor.start_room(bus_name, "test_room")
    assert :ok = Supervisor.stop_room(bus_name, "test_room")
    assert {:error, :not_found} = Supervisor.get_room(bus_name, "test_room")
  end

  test "stop_room/2 returns error for non-existent room", %{bus_name: bus_name} do
    assert {:error, :not_found} = Supervisor.stop_room(bus_name, "non_existent")
  end
end
