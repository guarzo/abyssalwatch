defmodule Abyssalwatch.Market.SDE.LoaderTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Abyssalwatch.Market.SDE.Loader
  alias Abyssalwatch.SDEFixture

  setup do
    tmp_root =
      System.tmp_dir!()
      |> Path.join("abyssalwatch-loader-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_root)
    on_exit(fn -> File.rm_rf!(tmp_root) end)
    {:ok, root: tmp_root}
  end

  test "stream_entry yields decoded maps lazily", %{root: root} do
    rows = [
      %{"_key" => 1, "name" => %{"en" => "Alpha"}},
      %{"_key" => 2, "name" => %{"en" => "Beta"}},
      %{"_key" => 3, "name" => %{"en" => "Gamma"}}
    ]

    zip =
      SDEFixture.write_zip(Path.join(root, "sde.zip"), %{
        "types.jsonl" => SDEFixture.jsonl(rows)
      })

    decoded =
      Loader.with_archive(zip, fn handle ->
        handle
        |> Loader.stream_entry("types.jsonl")
        |> Enum.to_list()
      end)

    assert decoded == rows
  end

  test "stream_entry skips malformed lines with a warning", %{root: root} do
    body =
      Enum.join(
        [
          ~s({"_key": 1}),
          "{not json}",
          ~s({"_key": 2})
        ],
        "\n"
      ) <> "\n"

    zip =
      SDEFixture.write_zip(Path.join(root, "sde.zip"), %{
        "types.jsonl" => body
      })

    {decoded, log} =
      with_log(fn ->
        Loader.with_archive(zip, fn handle ->
          handle |> Loader.stream_entry("types.jsonl") |> Enum.to_list()
        end)
      end)

    assert decoded == [%{"_key" => 1}, %{"_key" => 2}]
    assert log =~ "skipping malformed JSON"
  end
end
