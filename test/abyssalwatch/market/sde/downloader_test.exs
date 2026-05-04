defmodule Abyssalwatch.Market.SDE.DownloaderTest do
  use ExUnit.Case, async: true

  alias Abyssalwatch.Market.SDE.Downloader

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "head_latest reads x-sde-build-number directly from a 302 (no redirect follow)" do
    Req.Test.stub(Downloader, fn conn ->
      assert conn.method == "HEAD"

      conn
      |> Plug.Conn.put_resp_header(
        "location",
        "https://cdn.example/static-data-3328718-jsonl.zip"
      )
      |> Plug.Conn.put_resp_header("x-sde-build-number", "3328718")
      |> Plug.Conn.put_resp_header("etag", ~s("abc"))
      |> Plug.Conn.put_resp_header("last-modified", "Fri, 01 May 2026 11:48:57 GMT")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:ok, head} = Downloader.head_latest()
    assert head.build_number == 3_328_718
    assert head.etag == ~s("abc")
    assert head.last_modified == "Fri, 01 May 2026 11:48:57 GMT"
    assert head.url == "https://cdn.example/static-data-3328718-jsonl.zip"
  end

  test "head_latest falls back to URL-path parse when x-sde-build-number is absent" do
    Req.Test.stub(Downloader, fn conn ->
      conn
      |> Plug.Conn.put_resp_header(
        "location",
        "https://cdn.example/tranquility/eve-online-static-data-9999999-jsonl.zip"
      )
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:ok, head} = Downloader.head_latest()
    assert head.build_number == 9_999_999
    assert head.etag == nil
    assert head.last_modified == nil
    assert head.url == "https://cdn.example/tranquility/eve-online-static-data-9999999-jsonl.zip"
  end

  test "head_latest returns nil build_number when neither header nor URL carries one" do
    Req.Test.stub(Downloader, fn conn ->
      Plug.Conn.send_resp(conn, 200, "")
    end)

    assert {:ok, head} = Downloader.head_latest()
    assert head.build_number == nil
  end

  test "head_latest surfaces non-2xx/3xx status as :bad_status error" do
    Req.Test.stub(Downloader, fn conn ->
      Plug.Conn.send_resp(conn, 404, "")
    end)

    assert {:error, {:bad_status, 404}} = Downloader.head_latest()
  end
end
