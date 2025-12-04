defmodule Abyssalwatch.Fittings.Parsers.DNA do
  @moduledoc """
  Parser and encoder for EVE DNA fitting format.

  DNA is a compact single-line format using type IDs, enabling:
  - In-game chat links via `<url=fitting:DNA>Name</url>`
  - Compact URL sharing
  - Efficient database storage

  ## Format Grammar

  The DNA format structure is:
  ```
  SHIP_ID:SUBSYSTEMS:HIGHS:MEDS:LOWS:RIGS:DRONES:CARGO:CHARGES
  ```

  Each section contains module entries in format: `TYPE_ID;QUANTITY`
  Multiple modules are separated by colons within sections.

  ## Examples

  Simple fit:
  ```
  17703:2048;2:3170;2:2553;2:31788;2:31366:
  ```

  Complex fit with drones:
  ```
  29337:12058;1:12066;1:12070;1:12078;1:2281;4::3186;1:2364;1:1447;1:2024;1:2555;1::2488;5:2456;10::
  ```

  ## In-Game Link Format

  To create an in-game link:
  ```
  <url=fitting:17703:2048;2:3170;2>My Vexor Navy</url>
  ```

  Players can paste this in EVE chat and others can click to open the fit.
  """

  @doc """
  Parse a DNA string into a fitting structure.

  Returns {:ok, fitting} or {:error, reason}.
  """
  @spec parse(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse(nil), do: {:error, "DNA string cannot be nil"}
  def parse(""), do: {:error, "DNA string cannot be empty"}

  def parse(dna_string) when is_binary(dna_string) do
    # Remove any surrounding link markup if present
    dna = extract_dna_from_link(dna_string)
    parts = String.split(dna, ":")

    with {:ok, ship_type_id} <- parse_ship_id(Enum.at(parts, 0)),
         {:ok, subsystems} <- parse_slot_section(Enum.at(parts, 1, "")),
         {:ok, high_slots} <- parse_slot_section(Enum.at(parts, 2, "")),
         {:ok, med_slots} <- parse_slot_section(Enum.at(parts, 3, "")),
         {:ok, low_slots} <- parse_slot_section(Enum.at(parts, 4, "")),
         {:ok, rig_slots} <- parse_slot_section(Enum.at(parts, 5, "")),
         {:ok, drones} <- parse_slot_section(Enum.at(parts, 6, "")),
         {:ok, cargo} <- parse_slot_section(Enum.at(parts, 7, "")),
         {:ok, charges} <- parse_charges(Enum.at(parts, 8, "")) do
      {:ok,
       %{
         ship_type_id: ship_type_id,
         subsystems: subsystems,
         high_slots: high_slots,
         med_slots: med_slots,
         low_slots: low_slots,
         rig_slots: rig_slots,
         drones: drones,
         cargo: cargo,
         charges: charges
       }}
    end
  end

  def parse(_), do: {:error, "Invalid DNA input type"}

  @doc """
  Encode a fitting structure into a DNA string.

  The fitting map should have:
  - ship_type_id: integer
  - high_slots, med_slots, low_slots, rig_slots: list of %{type_id, quantity}
  - drones, cargo: list of %{type_id, quantity}
  - charges: list of type_ids
  """
  @spec encode(map()) :: String.t()
  def encode(fitting) when is_map(fitting) do
    [
      to_string(fitting[:ship_type_id] || fitting["ship_type_id"]),
      encode_slot_section(fitting[:subsystems] || fitting["subsystems"]),
      encode_slot_section(fitting[:high_slots] || fitting["high_slots"]),
      encode_slot_section(fitting[:med_slots] || fitting["med_slots"]),
      encode_slot_section(fitting[:low_slots] || fitting["low_slots"]),
      encode_slot_section(fitting[:rig_slots] || fitting["rig_slots"]),
      encode_slot_section(fitting[:drones] || fitting["drones"]),
      encode_slot_section(fitting[:cargo] || fitting["cargo"]),
      encode_charges(fitting[:charges] || fitting["charges"])
    ]
    |> Enum.join(":")
  end

  @doc """
  Generate an in-game chat link for the fitting.

  Players can paste this in EVE chat and others can click to open the fit.
  Format: `<url=fitting:DNA>Name</url>`
  """
  @spec to_ingame_link(map(), String.t()) :: String.t()
  def to_ingame_link(fitting, name) when is_map(fitting) do
    dna = encode(fitting)
    "<url=fitting:#{dna}>#{escape_name(name)}</url>"
  end

  @doc """
  Generate a shareable URL for the fitting.
  """
  @spec to_share_url(map(), String.t()) :: String.t()
  def to_share_url(fitting, base_url \\ nil) do
    base = base_url || Application.get_env(:abyssalwatch, :base_url, "https://abyssalwatch.com")
    dna = encode(fitting)
    "#{base}/fit/#{URI.encode(dna, &URI.char_unreserved?/1)}"
  end

  @doc """
  Extract DNA string from a share URL or return the string if already DNA format.
  """
  @spec from_share_url(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def from_share_url(url) when is_binary(url) do
    cond do
      # Full URL format
      String.contains?(url, "/fit/") ->
        case Regex.run(~r{/fit/(.+?)(?:\?|$)}, url) do
          [_, encoded_dna] -> {:ok, URI.decode(encoded_dna)}
          _ -> {:error, "Could not extract DNA from URL"}
        end

      # Already DNA format (starts with a number)
      Regex.match?(~r/^\d+:/, url) ->
        {:ok, url}

      # In-game link format
      String.starts_with?(url, "<url=fitting:") ->
        {:ok, extract_dna_from_link(url)}

      true ->
        {:error, "Unknown URL format"}
    end
  end

  # Private functions

  defp extract_dna_from_link(text) do
    # Match: <url=fitting:DNA>Name</url>
    case Regex.run(~r{<url=fitting:([^>]+)>}, text) do
      [_, dna] -> dna
      _ -> text
    end
  end

  defp parse_ship_id(nil), do: {:error, "Missing ship type ID"}
  defp parse_ship_id(""), do: {:error, "Missing ship type ID"}

  defp parse_ship_id(id_str) do
    case Integer.parse(String.trim(id_str)) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> {:error, "Invalid ship type ID: #{id_str}"}
    end
  end

  defp parse_slot_section(nil), do: {:ok, []}
  defp parse_slot_section(""), do: {:ok, []}

  defp parse_slot_section(section) do
    modules =
      section
      |> String.split(";")
      |> Enum.chunk_every(2)
      |> Enum.flat_map(fn
        [type_id_str, qty_str] when type_id_str != "" ->
          case {Integer.parse(type_id_str), Integer.parse(qty_str)} do
            {{type_id, ""}, {quantity, ""}} ->
              [%{type_id: type_id, quantity: quantity}]

            _ ->
              []
          end

        [type_id_str] when type_id_str != "" ->
          case Integer.parse(type_id_str) do
            {type_id, ""} -> [%{type_id: type_id, quantity: 1}]
            _ -> []
          end

        _ ->
          []
      end)

    {:ok, modules}
  end

  defp parse_charges(nil), do: {:ok, []}
  defp parse_charges(""), do: {:ok, []}

  defp parse_charges(section) do
    charges =
      section
      |> String.split(";")
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(fn id_str ->
        case Integer.parse(id_str) do
          {id, ""} -> [id]
          _ -> []
        end
      end)

    {:ok, charges}
  end

  defp encode_slot_section(nil), do: ""
  defp encode_slot_section([]), do: ""

  defp encode_slot_section(modules) when is_list(modules) do
    modules
    |> Enum.flat_map(fn
      %{type_id: type_id, quantity: quantity} -> ["#{type_id}", "#{quantity}"]
      %{"type_id" => type_id, "quantity" => quantity} -> ["#{type_id}", "#{quantity}"]
      _ -> []
    end)
    |> Enum.join(";")
  end

  defp encode_charges(nil), do: ""
  defp encode_charges([]), do: ""

  defp encode_charges(charges) when is_list(charges) do
    charges
    |> Enum.map(&to_string/1)
    |> Enum.join(";")
  end

  defp escape_name(name) do
    name
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
