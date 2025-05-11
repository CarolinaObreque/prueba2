defmodule Prueba2.TeamPositionSync do
  @moduledoc """
  Módulo para sincronizar las posiciones de los equipos entre nodos.
  """

  use GenServer
  alias Prueba2.P2PNetwork
  alias Prueba2.TeamManager

  # API Pública
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  @doc """
  Broadcast the position update to a random member of each other team.
  Can receive teams_info directly to avoid calling TeamManager.get_teams().
  """
  def broadcast_position_update(team_name, position, teams_info \\ nil) do
    # Get current username
    source_username = Application.get_env(:prueba2, :username)

    # Use provided teams_info if available, otherwise get it from TeamManager
    teams = if teams_info do
      teams_info
    else
      # Only use this in a separate process to avoid recursive calls
      Process.sleep(100) # Add a small delay to avoid race conditions
      TeamManager.get_teams()
    end

    # For each team different from the current one
    teams
    |> Enum.filter(fn {t_name, _} -> t_name != team_name end)
    |> Enum.each(fn {other_team_name, team_info} ->
      # Select a random member from the other team
      if length(team_info.players) > 0 do
        random_player = Enum.random(team_info.players)

        # Find this player's address
        P2PNetwork.get_peers()
        |> Enum.find(fn {_, username} -> username == random_player end)
        |> case do
          {address, _} ->
            # Send position update to the random player
            Task.start(fn ->
              url = "http://#{address}/api/position-update"
              payload = %{
                team_name: team_name,
                position: position,
                source_username: source_username,
                distribute: true
              }
              try do
                HTTPoison.post!(url, Jason.encode!(payload),
                  [{"Content-Type", "application/json"}], [timeout: 5_000])
              rescue
                _ -> handle_unreachable_peer(random_player, other_team_name)
              end
            end)
          nil -> nil # Player not found in peers
        end
      end
    end)
  end

  @doc """
  Distribute position update to all members of own team
  """
  def distribute_to_team(team_name, position, source_username) do
    # Get current user's team
    current_username = Application.get_env(:prueba2, :username)
    teams = TeamManager.get_teams()

    # Find current user's team
    current_team = find_user_team(teams, current_username)

    if current_team do
      # Get team members excluding self
      team_info = teams[current_team]
      team_members = Enum.filter(team_info.players, fn player ->
        player != current_username
      end)

      # Send update to all team members
      peers = P2PNetwork.get_peers()
      Enum.each(team_members, fn member ->
        Enum.find(peers, fn {_, username} -> username == member end)
        |> case do
          {address, _} ->
            Task.start(fn ->
              url = "http://#{address}/api/position-update"
              payload = %{
                team_name: team_name,
                position: position,
                source_username: source_username,
                distribute: false
              }
              try do
                HTTPoison.post!(url, Jason.encode!(payload),
                  [{"Content-Type", "application/json"}], [timeout: 5_000])
              rescue
                _ -> handle_unreachable_peer(member, current_team)
              end
            end)
          nil -> nil # Member not found in peers
        end
      end)
    end
  end
  # Handle unreachable peer by notifying network to remove them
  defp handle_unreachable_peer(username, team_name) do
    # Notify P2PNetwork to remove the peer
    P2PNetwork.remove_peer_by_username(username)

    # Check if team is now empty and handle accordingly
    teams = TeamManager.get_teams()
    team_info = teams[team_name]

    if team_info && length(team_info.players) <= 1 do
      # Team would be empty, notify shift manager
      if Process.whereis(Prueba2.ShiftManager) do
        Process.send(Prueba2.ShiftManager, {:team_empty, team_name}, [])
      end
    end
  end

  # Find which team a user belongs to
  defp find_user_team(teams, username) do
    Enum.find_value(teams, fn {team_name, team_data} ->
      if username in team_data.players, do: team_name, else: nil
    end)
  end

  # Iniciar sincronización periódica de posiciones
  def start_sync, do: GenServer.cast(__MODULE__, :start_sync)
  # Detener la sincronización periódica
  def stop_sync, do: GenServer.cast(__MODULE__, :stop_sync)

  # GenServer callbacks
  @impl true
  def init(_) do
    # Schedule first sync after 5 seconds
    Process.send_after(self(), :sync_positions, 5000)
    {:ok, %{}}
  end

  @impl true
  def handle_cast(:start_sync, state) do
    # Schedule first sync
    Process.send_after(self(), :sync_positions, 500)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:stop_sync, state) do
    # No necesitamos hacer nada especial, simplemente guardamos una variable
    # para indicar que la sincronización está desactivada
    {:noreply, Map.put(state, :sync_stopped, true)}
  end
  @impl true
  def handle_info(:sync_positions, state) do
    # Si la sincronización fue detenida, no hacemos nada
    if Map.get(state, :sync_stopped, false) do
      # No programamos otra sincronización
      {:noreply, state}
    else
      # Intentar sincronizar posiciones con manejo de errores
      try do
        # Get all teams and their positions
        teams = TeamManager.get_teams()
        current_username = Application.get_env(:prueba2, :username)
        current_team = find_user_team(teams, current_username)

        # For each team, broadcast its position
        if current_team do
          team_info = teams[current_team]
          # Only broadcast if the position is greater than 0
          if team_info && team_info.position > 0 do
            broadcast_position_update(current_team, team_info.position)
          end
        end
      rescue
        error ->
          # Si hay un error al obtener equipos, probablemente el juego terminó
          IO.puts("[SYNC] Error en sincronización: #{inspect(error)}")
      end

      # Programar la siguiente sincronización
      Process.send_after(self(), :sync_positions, 5000)
      {:noreply, state}
    end
  end
end
