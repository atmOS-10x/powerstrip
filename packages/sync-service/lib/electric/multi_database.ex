defmodule Electric.MultiDatabase do
  @moduledoc """
  Serves every database on the Postgres server of `DATABASE_URL` from one Electric, for development
  setups that give each git worktree, branch or test run a database of its own.

  Enabled with `ELECTRIC_MULTI_DATABASE=true`. A request for `/db/<name>/v1/shape` syncs from database
  `<name>`:

    * its stack starts on the first request, connecting with the credentials, host and options of
      `DATABASE_URL` (and `ELECTRIC_POOLED_DATABASE_URL`) with only the database name changed;
    * it replicates through a temporary slot with a random name, so a stopped stack holds no WAL;
    * it stops after `ELECTRIC_MULTI_DATABASE_IDLE_TIMEOUT` (default 30 minutes) without requests,
      and starts again, with fresh shape logs, on the next one;
    * it queries through a pool of `ELECTRIC_MULTI_DATABASE_POOL_SIZE` connections (default 5), so
      many databases fit within the server's `max_connections`.

  `ELECTRIC_MULTI_DATABASE_PATTERN` (a regular expression the whole name must match) limits which
  databases may be served. Requests without the prefix go to the database of `DATABASE_URL`,
  exactly as without this mode.
  """
  use GenServer
  require Logger

  @registry __MODULE__.Registry
  @supervisor __MODULE__.Supervisor
  @table __MODULE__
  @name ~r/\A[A-Za-z0-9_][A-Za-z0-9_\-]{0,62}\z/

  def children(opts) do
    [
      {Registry, name: @registry, keys: :unique},
      {DynamicSupervisor, name: @supervisor, strategy: :one_for_one},
      {__MODULE__, opts}
    ]
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether `name` may be served: a plain database name that matches the configured pattern."
  def valid_name?(name) do
    pattern = :persistent_term.get({__MODULE__, :pattern})
    Regex.match?(@name, name) and (is_nil(pattern) or Regex.match?(pattern, name))
  end

  @doc "Whether `name` is the database of `DATABASE_URL`, which the default stack serves."
  def default?(name), do: name == :persistent_term.get({__MODULE__, :default})

  @doc "The router options for database `name`, starting its stack unless it runs."
  def router_opts(name) do
    :ets.insert(@table, {{:seen, name}, now()})

    with [{_, opts}] <- :ets.lookup(@table, {:opts, name}),
         [_] <- Registry.lookup(@registry, name) do
      opts
    else
      _ ->
        opts = GenServer.call(__MODULE__, {:start, name}, :infinity)
        # A new stack has no shapes to serve read-only: hold the first requests until it replicates.
        Electric.StatusMonitor.wait_until_active(stack_id(name), timeout: 30_000)
        opts
    end
  end

  @doc "Stops the stack of database `name`, which drops its slot; the next request starts it again."
  def stop(name), do: GenServer.call(__MODULE__, {:stop, name}, :infinity)

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :persistent_term.put({__MODULE__, :pattern}, opts[:pattern])

    :persistent_term.put(
      {__MODULE__, :default},
      Keyword.fetch!(opts, :replication_connection_opts)[:database]
    )

    state = Map.new(opts)
    schedule_sweep(state)
    {:ok, state}
  end

  @impl true
  def handle_call({:start, name}, _from, state) do
    case {Registry.lookup(@registry, name), :ets.lookup(@table, {:opts, name})} do
      {[_], [{_, opts}]} ->
        {:reply, opts, state}

      _ ->
        {:reply, start_stack(name, state), state}
    end
  end

  def handle_call({:stop, name}, _from, state) do
    stop_stack(name, "requested")
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    cutoff = now() - state.idle_timeout

    for [name, seen] <- :ets.match(@table, {{:seen, :"$1"}, :"$2"}), seen < cutoff do
      stop_stack(name, "idle")
    end

    schedule_sweep(state)
    {:noreply, state}
  end

  defp stop_stack(name, reason) do
    for {pid, _} <- Registry.lookup(@registry, name) do
      Logger.notice("Stopping the stack of database #{inspect(name)}: #{reason}")
      DynamicSupervisor.terminate_child(@supervisor, pid)
    end

    :ets.delete(@table, {:seen, name})
    :ets.delete(@table, {:opts, name})
  end

  defp start_stack(name, state) do
    dir = Path.join(state.storage_dir, name)
    # Each start replicates through a new slot, so shape logs from an earlier start are stale.
    File.rm_rf!(dir)

    opts = [
      stack_id: stack_id(name),
      storage_dir: dir,
      storage: {Electric.ShapeCache.PureFileStorage, storage_dir: Path.join(dir, "shapes")},
      persistent_kv: {Electric.PersistentKV.Filesystem, :new!, root: Path.join(dir, "state")},
      shape_db_storage_dir: dir,
      replication_connection_opts: Keyword.put(state.replication_connection_opts, :database, name),
      query_connection_opts: Keyword.put(state.query_connection_opts, :database, name),
      replication_slot_temporary?: true,
      replication_slot_temporary_random_name?: true,
      pool_opts: [pool_size: state.pool_size]
    ]

    stack =
      opts
      |> Electric.Application.configuration()
      |> Keyword.put(:name, {:via, Registry, {@registry, name}})

    spec =
      Supervisor.child_spec({Electric.StackSupervisor, stack},
        id: name,
        restart: :temporary,
        significant: false
      )

    Logger.notice("Starting a stack for database #{inspect(name)}")
    {:ok, _pid} = DynamicSupervisor.start_child(@supervisor, spec)

    router_opts = opts |> Electric.Application.api_plug_opts() |> Electric.Plug.Router.init()
    :ets.insert(@table, {{:opts, name}, router_opts})
    router_opts
  end

  defp stack_id(name), do: "db:" <> name

  defp schedule_sweep(state),
    do: Process.send_after(self(), :sweep, min(state.idle_timeout, 60_000))

  defp now, do: System.monotonic_time(:millisecond)
end
