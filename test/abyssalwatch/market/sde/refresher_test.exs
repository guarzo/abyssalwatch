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
      Path.join(
        System.tmp_dir!(),
        "sde-refresher-fixture-#{System.unique_integer([:positive])}.zip"
      )

    on_exit(fn -> File.rm(fixture_zip) end)

    SDEFixture.write_zip(fixture_zip, %{
      "types.jsonl" =>
        SDEFixture.jsonl([
          # Real abyssal module — should be seeded.
          %{
            "_key" => 47702,
            "name" => %{"en" => "Abyssal Stasis Webifier"},
            "groupID" => 65,
            "metaGroupID" => 15,
            "published" => true
          },
          # Mutaplasmid consumable — same metaGroupID=15 but in
          # categoryID 17, so the filter must reject it. If this leaks
          # through, type_count will be 2 and the assertion below fails.
          %{
            "_key" => 85_673,
            "name" => %{"en" => "Glorified Unstable Vorton Tuning System Mutaplasmid"},
            "groupID" => 1964,
            "metaGroupID" => 15,
            "published" => true
          }
        ]),
      "groups.jsonl" =>
        SDEFixture.jsonl([
          %{"_key" => 65, "name" => %{"en" => "Stasis Web"}, "categoryID" => 7},
          %{"_key" => 1964, "name" => %{"en" => "Mutaplasmids"}, "categoryID" => 17}
        ]),
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
  end

  test "exits :error when HEAD fails" do
    Req.Test.stub(Downloader, fn conn ->
      Plug.Conn.send_resp(conn, 500, "boom")
    end)

    assert Refresher.run() == :error
  end

  test "prunes ModuleType rows that are no longer in the SDE filter result" do
    # Pre-seed a row that wouldn't match the current SDE filter (a leftover
    # mutaplasmid from an earlier broken-filter deploy).
    {:ok, _stale} =
      Ash.create(
        Abyssalwatch.Market.ModuleType,
        %{
          eve_type_id: 85_673,
          name: "Glorified Unstable Vorton Tuning System Mutaplasmid",
          category: "Other",
          slot_type: :med,
          base_attributes: %{}
        },
        upsert?: true,
        upsert_identity: :unique_eve_type_id
      )

    fixture_zip =
      Path.join(
        System.tmp_dir!(),
        "sde-prune-fixture-#{System.unique_integer([:positive])}.zip"
      )

    on_exit(fn -> File.rm(fixture_zip) end)

    SDEFixture.write_zip(fixture_zip, %{
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
      "groups.jsonl" =>
        SDEFixture.jsonl([
          %{"_key" => 65, "name" => %{"en" => "Stasis Web"}, "categoryID" => 7}
        ]),
      "typeDogma.jsonl" => "",
      "dogmaAttributes.jsonl" => ""
    })

    fixture_body = File.read!(fixture_zip)

    Req.Test.stub(Downloader, fn conn ->
      cond do
        conn.method == "HEAD" ->
          conn
          |> Plug.Conn.put_resp_header("x-sde-build-number", "888888")
          |> Plug.Conn.send_resp(200, "")

        conn.method == "GET" ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/zip")
          |> Plug.Conn.send_resp(200, fixture_body)
      end
    end)

    assert {:ok, %{build_number: 888_888, type_count: 1}} = Refresher.run()

    {:ok, remaining} = Ash.read(Abyssalwatch.Market.ModuleType)
    eve_type_ids = Enum.map(remaining, & &1.eve_type_id)
    assert 47_702 in eve_type_ids
    refute 85_673 in eve_type_ids
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
