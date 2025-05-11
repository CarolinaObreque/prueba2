defmodule Prueba2.ShiftManager do
  @moduledoc """
  Gestor de turnos para el juego de dados.
  Se encarga de controlar qué jugador debe tirar el dado en cada momento.
  """

  use GenServer
  import IO.ANSI
  alias Prueba2.P2PNetwork
  alias Prueba2.TeamManager
  alias Prueba2.GameManager

  # Colores para mensajes
  @info_color green()
  @turn_color bright() <> magenta()
  @reset reset()

  # API Pública
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Inicia la gestión de turnos cuando todos los equipos estén listos.
  """
  def start_game do
    GenServer.call(__MODULE__, :start_game)
  end

  @doc """
  Notifica que el jugador actual ha terminado su turno.
  """
  def notify_turn_completed(player_name, team_name, dice_value) do
    GenServer.cast(__MODULE__, {:turn_completed, player_name, team_name, dice_value})
  end

  @doc """
  Obtiene el jugador que tiene el turno actual.
  """
  def get_current_turn do
    GenServer.call(__MODULE__, :get_current_turn)
  end
  @doc """
  Verifica si es el turno de un jugador específico.
  """
  def is_player_turn?(player_name) do
    case get_current_turn() do
      {:ok, current_player, _team_name} -> current_player == player_name
      _ -> false
    end
  end

  @doc """
  Verifica si un equipo específico puede lanzar el dado en este momento.
  """


  # Callbacks de GenServer
  @impl true
  def init(_) do
    {:ok, %{
      game_started: false,
      teams_queue: [],
      players_by_team: %{},
      teams_rolled: %{},  # Equipos que ya lanzaron
      last_rolls: %{}     # Último lanzamiento de cada equipo
    }}
  end
  @impl true
  def handle_info(:game_over, state) do
    # Terminar el juego inmediatamente
    broadcast_game_message("El juego ha terminado por decision de otro nodo!")
    {:noreply, %{state | game_started: false}}
  end

  @impl true
  def handle_info({:check_win, team_name}, state) do
    # Verificar si un equipo ganó por sincronización de posición
    if state.game_started do
      case GameManager.game_finished?() do
        {:ok, true, winner} ->
          handle_team_victory(winner)
          {:noreply, %{state | game_started: false}}

        _ ->
          # Verificar si el equipo específico ha llegado a la posición ganadora
          case TeamManager.get_team_position(team_name) do
            {:ok, position} when position >= 100 ->
              handle_team_victory(team_name)
              {:noreply, %{state | game_started: false}}

            _ ->
              {:noreply, state}
          end
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:auto_start_game, state) do
    if not state.game_started do
      # Double-check that all teams are ready
      if Prueba2.TeamManager.all_teams_ready?() do
        # Iniciar el juego directamente aquí
        teams = TeamManager.get_teams()
        teams_with_players = Enum.filter(teams, fn {_, team_info} ->
          length(team_info.players) > 0 && team_info.ready
        end)

        teams_queue = Enum.map(teams_with_players, fn {team_name, _} -> team_name end)
        players_by_team = Enum.map(teams_with_players, fn {team_name, team_info} ->
          {team_name, team_info.players}
        end) |> Enum.into(%{})

        if length(teams_queue) >= 2 do
          # Inicializar el juego
          GameManager.initialize_game(teams_queue)

          # Iniciar sincronización periódica de posiciones
          Prueba2.TeamPositionSync.start_sync()

          # Actualizar el estado - todos los equipos pueden tirar
          new_state = %{
            state |
            game_started: true,
            teams_queue: teams_queue,
            players_by_team: players_by_team,
            teams_rolled: %{},
            last_rolls: %{}
          }          # Notificar el inicio del juego a todos
          broadcast_game_message("El juego ha comenzado! Todos los equipos deben lanzar el dado.")

          # Notificar a todos los jugadores que tiren
          Enum.each(teams_queue, fn team ->
            players = players_by_team[team]
            first_player = List.first(players)
            notify_player_to_roll(first_player, team)
          end)

          {:noreply, new_state}
        else
          {:noreply, state}
        end
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:start_game, _from, state) do
    if state.game_started do
      {:reply, {:error, "El juego ya está en curso"}, state}
    else
      # Verificar si todos los equipos están listos
      all_ready = TeamManager.all_teams_ready?()

      if all_ready do
        # Preparar el juego
        teams = TeamManager.get_teams()
        teams_with_players = Enum.filter(teams, fn {_, team_info} ->
          length(team_info.players) > 0 && team_info.ready
        end)

        teams_queue = Enum.map(teams_with_players, fn {team_name, _} -> team_name end)
        players_by_team = Enum.map(teams_with_players, fn {team_name, team_info} ->
          {team_name, team_info.players}
        end) |> Enum.into(%{})

        if length(teams_queue) >= 2 do
          # Inicializar el juego
          GameManager.initialize_game(teams_queue)

          # Iniciar sincronización periódica de posiciones
          Prueba2.TeamPositionSync.start_sync()

          # Actualizar el estado
          new_state = %{
            state |
            game_started: true,
            teams_queue: teams_queue,
            players_by_team: players_by_team,
            teams_rolled: %{},
            last_rolls: %{
            }
          }          # Notificar el inicio del juego a todos
          broadcast_game_message("El juego ha comenzado!")
          broadcast_game_message("Todos los equipos deben lanzar su dado")

          # Notificar a los jugadores
          Enum.each(teams_queue, fn team ->
            players = players_by_team[team]
            first_player = List.first(players)
            notify_player_to_roll(first_player, team)
          end)

          {:reply, {:ok, "Juego iniciado"}, new_state}
        else
          {:reply, {:error, "Se necesitan al menos 2 equipos con jugadores listos"}, state}
        end
      else
        {:reply, {:error, "No todos los equipos están listos"}, state}
      end
    end
  end

  @impl true
  def handle_call(:get_current_turn, _from, state) do
    if state.game_started do
      pending_teams = Enum.filter(state.teams_queue, fn team ->
        not Map.has_key?(state.teams_rolled, team)
      end)

      if length(pending_teams) > 0 do
        next_team = List.first(pending_teams)
        players = state.players_by_team[next_team]
        first_player = List.first(players)
        {:reply, {:ok, first_player, next_team}, state}
      else
        {:reply, {:error, "Esperando a que comience la siguiente ronda"}, state}
      end
    else
      {:reply, {:error, "El juego no ha comenzado"}, state}
    end
  end

  @impl true
  def handle_cast({:turn_completed, player_name, team_name, dice_value}, state) do
    if not state.game_started do
      {:noreply, state}
    else
      # Registrar que este equipo ya lanzó
      new_teams_rolled = Map.put(state.teams_rolled, team_name, true)
      new_last_rolls = Map.put(state.last_rolls, team_name, %{
        player: player_name,
        value: dice_value
      })

      # Procesar el turno en el GameManager
      case GameManager.process_turn(team_name, dice_value) do
        {:ok, result} ->
          message = Map.get(result, :message, "Avanza a la posición #{result.new_position}")
          broadcast_game_message("#{player_name} del equipo #{team_name} lanzó un #{dice_value}. #{message}")

          # Verificar inmediatamente si este equipo ha ganado
          if result.is_winner do
            handle_team_victory(team_name)
            {:noreply, %{state | game_started: false}}
          else
            # Verificar si todos los equipos han lanzado
            all_teams_rolled = Enum.all?(state.teams_queue, fn team ->
              Map.has_key?(new_teams_rolled, team)
            end)

            if all_teams_rolled do
              # Verificar si el juego ha terminado
              case GameManager.game_finished?() do
                {:ok, true, winner} ->
                  handle_team_victory(winner)
                  {:noreply, %{state | game_started: false}}

                _ ->                  # Iniciar nueva ronda (todos pueden volver a tirar)
                  broadcast_game_message("Una nueva ronda comienza! Todos los equipos deben lanzar el dado.")

                  # Notificar a todos los jugadores
                  Enum.each(state.teams_queue, fn team ->
                    players = state.players_by_team[team]
                    first_player = List.first(players)
                    notify_player_to_roll(first_player, team)
                  end)

                  # Actualizar estado para la nueva ronda
                  new_state = %{state |
                    teams_rolled: %{},
                    last_rolls: new_last_rolls
                  }
                  {:noreply, new_state}
              end
            else
              # Algunos equipos aún no han lanzado
              pending_teams = Enum.filter(state.teams_queue, fn team ->
                not Map.has_key?(new_teams_rolled, team)
              end)

            if length(pending_teams) > 0 do
                next_team = List.first(pending_teams)
                broadcast_game_message("Esperando al equipo #{next_team}")
                # Establecer el equipo que está permitido lanzar ahora
              end

              {:noreply, %{state | teams_rolled: new_teams_rolled, last_rolls: new_last_rolls}}
            end
          end

        {:error, reason} ->
          broadcast_game_message("Error: #{reason}")
          {:noreply, state}
      end
    end
  end

  @impl true
  def handle_info({:team_empty, team_name}, state) do
    if state.game_started do
      # Eliminar equipo de la cola de turnos
      new_teams_queue = Enum.reject(state.teams_queue, fn t -> t == team_name end)
      new_players_by_team = Map.delete(state.players_by_team, team_name)

      # Verificar si aún quedan suficientes equipos para continuar
      if length(new_teams_queue) < 2 do
        # No hay suficientes equipos, terminar juego
        if length(new_teams_queue) > 0 do
          remaining_team = List.first(new_teams_queue)
          handle_team_victory(remaining_team)
        else
          broadcast_game_message("El juego ha terminado porque no quedan equipos suficientes")
          if Process.whereis(Prueba2.UserInterface) do
            Process.send(Prueba2.UserInterface, :game_over, [])
          end
        end
        {:noreply, %{state | game_started: false}}
      else
        # Actualizar estado sin el equipo eliminado
        broadcast_game_message("El equipo #{team_name} ha sido eliminado por falta de jugadores")
        new_state = %{state |
          teams_queue: new_teams_queue,
          players_by_team: new_players_by_team,
          teams_rolled: Map.drop(state.teams_rolled, [team_name])
        }
          # Verificar si todos los equipos restantes ya tiraron
        if Enum.all?(new_teams_queue, fn team -> Map.has_key?(new_state.teams_rolled, team) end) do
          # Reiniciar ronda
          updated_state = %{new_state | teams_rolled: %{}}
          broadcast_game_message("Nueva ronda iniciada después de eliminación de equipo")
          {:noreply, updated_state}
        else
          {:noreply, new_state}
        end
      end
    else
      {:noreply, state}
    end
  end

  # Funciones privadas  # Centraliza la lógica cuando un equipo gana el juego
  defp handle_team_victory(team_name) do
    # Intentar conseguir la posición meta (si TeamManager aún está vivo)
    try do
      if Process.whereis(Prueba2.GameManager) do
        # Si existe GameManager, obtenemos el estado del juego para saber la posición meta
        case Prueba2.GameManager.get_game_state() do
          {:ok, game_state} ->
            goal_position = Map.get(:get_game_state, :goal, 100)
          _ -> nil
        end
      end
    rescue
      _ -> nil # Silenciar errores, usar valor por defecto
    end

    broadcast_game_message("El equipo #{team_name} ha ganado el juego al llegar a la posición #{goal_position}!")

    # Enviar un mensaje especial para asegurar que todos los nodos actualicen su estado
    P2PNetwork.broadcast_message("GAME_OVER: El equipo #{team_name} ha ganado en la posición #{goal_position}")

    # Intentar detener la sincronización de posiciones
    try do
      if Process.whereis(Prueba2.TeamPositionSync) do
        GenServer.cast(Prueba2.TeamPositionSync, :stop_sync)
      end
    rescue
      _ -> nil # Silenciar errores
    end

    # Enviar mensaje a la interfaz de usuario para volver al menú principal
    if Process.whereis(Prueba2.UserInterface) do
      Process.send(Prueba2.UserInterface, :game_over, [])
    end
  end  # Notificar a un jugador que es su turno mediante un mensaje de sistema
  defp notify_player_to_roll(player_name, team_name) do
    # Establecer el equipo que está permitido lanzar ahora

    if player_name == Application.get_env(:prueba2, :username) do
      IO.puts(@turn_color <> "[TURNO] Tu equipo (#{team_name}) debe lanzar el dado. Presiona ENTER para tirar " <> @reset)
    end
  end

  # Difunde un mensaje de juego siguiendo el patrón de comunicación eficiente
  defp broadcast_game_message(message) do
    # Mostrar el mensaje localmente
    IO.puts(@info_color <> "[JUEGO] " <> @reset <> message)

    # Obtener todos los equipos
    teams = TeamManager.get_teams()
    source_username = Application.get_env(:prueba2, :username)

    # Para cada equipo diferente al nuestro, enviar a un miembro aleatorio
    current_team = find_user_team(teams, source_username)

    if current_team do
      # Enviar el mensaje primero a todos los miembros de nuestro equipo
      notify_team_members(current_team, teams, message)

      # Luego enviar a un miembro aleatorio de cada equipo contrario
      teams
      |> Enum.filter(fn {t_name, _} -> t_name != current_team end)
      |> Enum.each(fn {other_team, team_info} ->
        if length(team_info.players) > 0 do
          random_player = Enum.random(team_info.players)
          send_game_message(random_player, message, true)
        end
      end)
    else
      # Si no estamos en un equipo, usar el método tradicional
      P2PNetwork.broadcast_message(message)
    end
  end

  # Notifica a todos los miembros del equipo sobre un mensaje de juego
  defp notify_team_members(team_name, teams, message) do
    current_username = Application.get_env(:prueba2, :username)

    if team_name && Map.has_key?(teams, team_name) do
      team_info = teams[team_name]

      # Enviar a cada miembro de mi equipo (excluyéndome)
      team_info.players
      |> Enum.filter(fn player -> player != current_username end)
      |> Enum.each(fn member ->
        send_game_message(member, message, false)
      end)
    end
  end

  # Envía un mensaje a un jugador específico
  defp send_game_message(username, message, distribute) do
    P2PNetwork.get_peers()
    |> Enum.find(fn {_, name} -> name == username end)
    |> case do
      {address, _} ->
        Task.start(fn ->
          url = "http://#{address}/api/game-message"
          payload = %{
            message: message,
            source_username: Application.get_env(:prueba2, :username),
            distribute: distribute
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

  # Encuentra el equipo al que pertenece un usuario
  defp find_user_team(teams, username) do
    Enum.find_value(teams, fn {team_name, team_data} ->
      if username in team_data.players, do: team_name, else: nil
    end)
  end

  # Maneja el caso de un peer inalcanzable
  defp handle_unreachable_peer(username) do
    # Notificar a P2PNetwork para eliminar al peer
    P2PNetwork.remove_peer_by_username(username)
  end
end
