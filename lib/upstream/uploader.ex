defmodule Upstream.Uploader do
  @moduledoc """
  Manages Supervisors for Uploaders
  """

  use Supervisor

  alias Upstream.{
    Job, Uploader, Worker
  }

  @spec start_link(any()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(_args) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  @spec init(any()) :: {:ok, {%{intensity: any(), period: any(), strategy: any()}, [any()]}}
  def init(_) do
    children = [
      {__MODULE__.Chunk, []},
      {__MODULE__.LargeFile, []},
      {__MODULE__.StandardFile, []},
      {Task.Supervisor, name: __MODULE__.TaskSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec upload_chunk!(binary(), binary() | %{file_id: any(), index: any()}) :: {:error, any()} | {:ok, any()}
  def upload_chunk!(chunk_path, params) do
    job = Job.create(chunk_path, params)
    if Job.State.errored?(job), do: Job.State.retry(job)

    start_and_register(job, fn ->
      start_uploader(Chunk, job)
    end)
  end

  @spec upload_file!(binary(), binary() | %{file_id: any(), index: any()}, any()) :: {:error, any()} | {:ok, any()}
  def upload_file!(file_path, name, metadata \\ %{}) do
    job = Job.create(file_path, name, metadata)
    if Job.State.errored?(job), do: Job.State.retry(job)

    file_type =
      if job.threads == 1,
        do: StandardFile,
        else: LargeFile

    start_and_register(job, fn ->
      start_uploader(file_type, job)
    end)
  end

  defp start_and_register(job, on_start) do
    if Job.State.uploading?(job) || Job.State.done?(job) do
      get_result_or_start(job, on_start)
    else
      on_start.()
    end
  end

  defp get_result_or_start(job, on_start) do
    case Job.State.get_result(job) do
      {:ok, reply} ->
        {:ok, reply}

      {:error, %{error: :no_reply}} ->
        Job.State.retry(job)
        on_start.()
    end
  end

  defp start_uploader(module, job) do
    with {:ok, pid} <- DynamicSupervisor.start_link(Module.concat(Uploader, module), [job]),
         {:ok, result} <- Module.concat(Worker, module).upload(pid)
    do
      {:ok, result}
    else
      {:error, reason} -> {:error, reason}
    end
  end
end
