defmodule Abyssalwatch.Market.SDE.RefresherTest do
  use Abyssalwatch.DataCase, async: false

  alias Abyssalwatch.Market.SDE.{Downloader, Refresher, Version}
  alias Abyssalwatch.SDEFixture

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "skips download when build_number matches stored marker" do
    seed_marker(build_number: 3_328_718, type_count: 50)

    Req.Test.stub(Downloader, fn conn ->
      assert conn.method == "HEAD"

      conn
      |> Plug.Conn.put_resp_header("x-sde-build-number", "3328718")
      |> Plug.Conn.put_resp_header("etag", ~s("abc"))
      |> Plug.Conn.send_resp(200, "")
    end)

    assert Refresher.run() == :up_to_date
    assert {:ok, [%{build_number: 3_328_718}]} = Ash.read(Version)
  end

  test "downloads and seeds when marker is missing" do
    fixture_zip =
      Path.join(System.tmp_dir!(), "sde-refresher-fixture.zip")
      |> SDEFixture.write_zip(%{
        "types.jsonl" =>
          SDEFixture.jsonl([
            %{
              "_key" => 47702,
              "name" => %{"en" => "Abyssal Stasis Webifier"},
              "groupID" => 65,
              "metaGroupID" => 15,
              "published" => true
            }
          ]),
        "groups.jsonl" => SDEFixture.jsonl([%{"_key" => 65, "name" => %{"en" => "Stasis Web"}}]),
        "typeDogma.jsonl" => "",
        "dogmaAttributes.jsonl" => ""
      })

    fixture_body = File.read!(fixture_zip)

    Req.Test.stub(Downloader, fn conn ->
      cond do
        conn.method == "HEAD" ->
          conn
          |> Plug.Conn.put_resp_header("x-sde-build-number", "999999")
          |> Plug.Conn.send_resp(200, "")

        conn.method == "GET" ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/zip")
          |> Plug.Conn.send_resp(200, fixture_body)
      end
    end)

    assert {:ok, %{build_number: 999_999, type_count: 1}} = Refresher.run()

    File.rm!(fixture_zip)
  end

  test "exits :error when HEAD fails" do
    Req.Test.stub(Downloader, fn conn ->
      Plug.Conn.send_resp(conn, 500, "boom")
    end)

    assert Refresher.run() == :error
  end

  defp seed_marker(attrs) do
    base = %{
      id: 1,
      build_number: 0,
      etag: nil,
      last_modified: nil,
      seeded_at: DateTime.utc_now() |> DateTime.truncate(:second),
      type_count: 0
    }

    {:ok, _} =
      Ash.create(Version, Map.merge(base, Map.new(attrs)), action: :upsert, upsert?: true)
  end
end
