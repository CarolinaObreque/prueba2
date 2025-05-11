defmodule Prueba2.GameManager do
  @moduledoc """
  Gestor de la lógica del juego de dados.
  Maneja las reglas, el avance de posiciones y determina el ganador.
  """
  use GenServer
  alias Prueba2.TeamManager
  alias Prueba2.P2PNetwork

  # Meta del juego: posición para ganar (desde variable de entorno o valor por defecto)
  @goal_position 50

  # API Pública
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Inicializa el juego con los equipos participantes.
  """
  def initialize_game(teams) do
    GenServer.call(__MODULE__, {:initialize_game, teams})
  end

  @doc """
  Procesa el turno de un equipo con el valor del dado lanzado.
  """
  def process_turn(team_name, dice_value) do
    GenServer.call(__MODULE__, {:process_turn, team_name, dice_value})
  end

  @doc """
  Verifica si el juego ha terminado (algún equipo llegó a la meta).
  """
  def game_finished? do
    GenServer.call(__MODULE__, :game_finished)
  end

  @doc """
  Obtiene el nombre del equipo ganador, si existe.
  """
  def get_winner do
    GenServer.call(__MODULE__, :get_winner)
  end

  @doc """
  Obtiene el estado actual del juego.
  """
  def get_game_state do
    GenServer.call(__MODULE__, :get_game_state)
  end

  # Callbacks de GenServer
  @impl true
  def init(_) do
    {:ok, %{
      game_active: false,
      teams: [],
      positions: %{},
      current_turn: nil,
      winner: nil,
      turn_history: []
    }}
  end

  @impl true
  def handle_call({:initialize_game, teams}, _from, state) do
    # Inicializar posiciones de los equipos a 0
    positions = Enum.map(teams, fn team -> {team, 0} end) |> Enum.into(%{})

    # Actualizar el estado del juego
    new_state = %{
      state |
      game_active: true,
      teams: teams,
      positions: positions,
      current_turn: nil,
      winner: nil,
      turn_history: []
    }

    # Establecer posiciones iniciales en el TeamManager
    Enum.each(teams, fn team ->
      TeamManager.update_team_position(team, 0)
    end)

    {:reply, {:ok, "Juego inicializado"}, new_state}
  end

  @impl true
  def handle_call({:process_turn, team_name, dice_value}, _from, state) do
    if not state.game_active do
      {:reply, {:error, "El juego no está activo"}, state}
    else
      # Verificar que el equipo exista
      if not Enum.member?(state.teams, team_name) do
        {:reply, {:error, "Equipo no encontrado en el juego"}, state}      else        # Calcular nueva posición
        current_position = Map.get(state.positions, team_name, 0)
        dice_value = min(dice_value, @goal_position - current_position)  # Limitar el valor para no pasarse de 100
        new_position = current_position + dice_value

        # Verificar si se llegó a la meta
        {final_position, message, winner} =
          if new_position >= @goal_position do
            {@goal_position, "¡Ha llegado a la meta y ganó el juego!", team_name}
          else
            {new_position, "Avanza a la posición #{new_position}", nil}
          end

        # Actualizar posición en el estado
        updated_positions = Map.put(state.positions, team_name, final_position)

        # Actualizar posición en el TeamManager
        TeamManager.update_team_position(team_name, final_position)

        # Actualizar historial de turnos
        turn_record = %{
          team: team_name,
          dice: dice_value,
          from_position: current_position,
          to_position: final_position,
          timestamp: :os.system_time(:second)
        }

        # Actualizar estado del juego
        new_state = %{
          state |
          positions: updated_positions,
          current_turn: team_name,
          turn_history: [turn_record | state.turn_history],
          winner: winner
        }        # Si hay un ganador, marcar el juego como inactivo
        new_state = if winner, do: %{new_state | game_active: false}, else: new_state

        # Formato del resultado para la respuesta
        result = %{
          team: team_name,
          dice_value: dice_value,
          old_position: current_position,
          new_position: final_position,
          message: message,
          is_winner: winner != nil
        }

        # Notificación de turno a los miembros del equipo del jugador actual
        notify_team_about_turn(team_name, result)

        {:reply, {:ok, result}, new_state}
      end
    end
  end
  @impl true
  def handle_call(:game_finished, _from, state) do
    # Verificar si hay un ganador o si algún equipo alcanzó o superó la meta
    winner = state.winner

    if winner do
      {:reply, {:ok, true, winner}, state}
    else
      # Verificar si algún equipo llegó a la meta
      winner_team = Enum.find(state.teams, fn team ->
        position = Map.get(state.positions, team, 0)
        position >= @goal_position
      end)

      if winner_team do
        # Actualizar el estado con el ganador
        new_state = %{state | winner: winner_team, game_active: false}
        {:reply, {:ok, true, winner_team}, new_state}
      else
        {:reply, {:ok, false, nil}, state}
      end
    end
  end

  @impl true
  def handle_call(:get_winner, _from, state) do
    {:reply, {:ok, state.winner}, state}
  end

  @impl true
  def handle_call(:get_game_state, _from, state) do    game_state = %{
      active: state.game_active,
      teams: state.teams,
      positions: state.positions,
      turn_history: Enum.take(state.turn_history, 5),
      winner: state.winner,
      goal: @goal_position
    }
    {:reply, {:ok, game_state}, state}
  end

  # Notifica a todos los miembros del equipo sobre un turno
  defp notify_team_about_turn(team_name, turn_result) do
    # Get current username
    source_username = Application.get_env(:prueba2, :username)

    # Obtener miembros del equipo
    teams = TeamManager.get_teams()

    if Map.has_key?(teams, team_name) do
      team_info = teams[team_name]

      # Notificar a cada miembro del equipo (excepto uno mismo)
      team_info.players
      |> Enum.filter(fn player -> player != source_username end)
      |> Enum.each(fn member ->
        send_turn_update_to_member(member, turn_result)
      end)
    end
  end

  # Envía actualización de turno a un miembro del equipo
  defp send_turn_update_to_member(username, turn_result) do
    P2PNetwork.get_peers()
    |> Enum.find(fn {_, name} -> name == username end)
    |> case do
      {address, _} ->
        Task.start(fn ->
          url = "http://#{address}/api/turn-update"
          payload = %{
            team: turn_result.team,
            dice_value: turn_result.dice_value,
            old_position: turn_result.old_position,
            new_position: turn_result.new_position,
            message: turn_result.message,
            is_winner: turn_result.is_winner,
            source_username: Application.get_env(:prueba2, :username)
          }
          try do
            HTTPoison.post!(url, Jason.encode!(payload),
              [{"Content-Type", "application/json"}], [timeout: 5_000])
          rescue
            _ -> handle_unreachable_peer(username)
          end
        end)
      nil -> nil
    end
  end

  # Maneja peers no disponibles
  defp handle_unreachable_peer(username) do
    P2PNetwork.remove_peer_by_username(username)
  end
end
