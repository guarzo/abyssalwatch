defmodule Abyssalwatch.Watchlists.Discord.MessageBuilder do
  @moduledoc """
  Builds Discord embed messages for watchlist notifications.

  Uses EVE Online-themed styling with rich embeds containing:
  - Module details and attributes
  - Price and score information
  - Direct links to Mutamarket listings
  - Watchlist context

  Discord embed limits:
  - Title: 256 characters
  - Description: 4096 characters
  - Fields: 25 maximum, name 256 chars, value 1024 chars
  - Total embed: 6000 characters
  """

  # EVE Online-inspired colors (hex values for Discord)
  @color_excellent 0x00FF00
  @color_good 0x30C5FF
  @color_moderate 0xFFAA00
  @color_info 0x3498DB

  @mutamarket_base_url "https://mutamarket.com/modules"

  @type match :: %{
          module: map(),
          watchlist: map(),
          score: float()
        }

  @doc """
  Build a Discord webhook payload for watchlist matches.

  ## Options
    - `:mention_role_id` - Discord role ID to @mention
    - `:include_details` - Whether to include attribute details (default: true)
  """
  @spec build_notification(map(), [map()], keyword()) :: map()
  def build_notification(watchlist, matches, opts \\ []) do
    mention_role_id = Keyword.get(opts, :mention_role_id)
    include_details = Keyword.get(opts, :include_details, true)

    %{
      username: "AbyssalWatch",
      avatar_url: nil,
      content: build_content(watchlist, matches, mention_role_id),
      embeds: build_embeds(watchlist, matches, include_details)
    }
  end

  @doc """
  Build a notification for a single module match.
  """
  @spec build_single_notification(map(), map(), keyword()) :: map()
  def build_single_notification(notification, watchlist, opts \\ []) do
    mention_role_id = Keyword.get(opts, :mention_role_id)
    include_details = Keyword.get(opts, :include_details, true)

    module = %{
      external_id: notification.module_external_id,
      name: notification.module_name,
      price: notification.module_price,
      score: notification.module_score,
      attributes: notification.module_attributes
    }

    %{
      username: "AbyssalWatch",
      avatar_url: nil,
      content: build_single_content(watchlist, mention_role_id),
      embeds: [build_module_embed(module, watchlist, include_details)]
    }
  end

  # Content building (the text above embeds)

  defp build_content(watchlist, matches, mention_role_id) do
    mention = if mention_role_id, do: "<@&#{mention_role_id}> ", else: ""
    count = length(matches)

    "#{mention}**#{count}** new module#{if count != 1, do: "s"} matched watchlist **#{watchlist.name}**!"
  end

  defp build_single_content(watchlist, mention_role_id) do
    mention = if mention_role_id, do: "<@&#{mention_role_id}> ", else: ""
    "#{mention}New match for watchlist **#{watchlist.name}**!"
  end

  # Embed building

  defp build_embeds(watchlist, matches, include_details) do
    # Limit to 10 embeds (Discord limit is 10)
    matches
    |> Enum.take(10)
    |> Enum.map(fn match ->
      module = extract_module_data(match)
      build_module_embed(module, watchlist, include_details)
    end)
  end

  defp extract_module_data(%{module: module}) when is_map(module), do: module

  defp extract_module_data(match) when is_map(match) do
    %{
      external_id: match[:module_external_id] || match["module_external_id"],
      name: match[:module_name] || match["module_name"] || match[:name] || match["name"],
      price: match[:module_price] || match["module_price"] || match[:price] || match["price"],
      score: match[:module_score] || match["module_score"] || match[:score] || match["score"],
      attributes:
        match[:module_attributes] || match["module_attributes"] || match[:attributes] ||
          match["attributes"] || %{}
    }
  end

  defp build_module_embed(module, watchlist, include_details) do
    external_id = module[:external_id] || module["external_id"]
    name = module[:name] || module["name"] || "Unknown Module"
    price = module[:price] || module["price"]
    score = module[:score] || module["score"]
    attributes = module[:attributes] || module["attributes"] || %{}

    embed = %{
      title: truncate(name, 256),
      url: build_mutamarket_url(external_id),
      color: score_to_color(score),
      fields: build_fields(price, score, watchlist, attributes, include_details),
      footer: %{
        text: "AbyssalWatch • #{watchlist.module_type_name || "Abyssal Module"}"
      },
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Add description if we have a module ID
    if external_id do
      Map.put(embed, :description, "Module ID: `#{external_id}`")
    else
      embed
    end
  end

  defp build_fields(price, score, watchlist, attributes, include_details) do
    fields = []

    # Price field
    fields =
      if price do
        [
          %{
            name: "Price",
            value: format_price(price),
            inline: true
          }
          | fields
        ]
      else
        fields
      end

    # Score field
    fields =
      if score do
        [
          %{
            name: "Score",
            value: format_score(score),
            inline: true
          }
          | fields
        ]
      else
        fields
      end

    # Watchlist criteria summary
    fields = [
      %{
        name: "Watchlist",
        value: watchlist.name,
        inline: true
      }
      | fields
    ]

    # Add attribute details if requested and available
    fields =
      if include_details and is_map(attributes) and map_size(attributes) > 0 do
        attr_fields = build_attribute_fields(attributes, watchlist)
        fields ++ attr_fields
      else
        fields
      end

    # Reverse to maintain order (we prepended)
    Enum.reverse(fields)
  end

  defp build_attribute_fields(attributes, watchlist) do
    important = watchlist.important_attributes || %{}
    unimportant = watchlist.unimportant_attributes || %{}

    # Build a single field with key attributes
    highlighted_attrs =
      attributes
      |> Enum.filter(fn {key, _} ->
        Map.has_key?(important, key) or Map.has_key?(unimportant, key)
      end)
      |> Enum.map(fn {key, value} ->
        indicator =
          cond do
            Map.has_key?(important, key) -> "+"
            Map.has_key?(unimportant, key) -> "-"
            true -> " "
          end

        "#{indicator} **#{key}**: #{format_attribute_value(value)}"
      end)
      |> Enum.take(10)
      |> Enum.join("\n")

    if String.length(highlighted_attrs) > 0 do
      [
        %{
          name: "Matched Attributes",
          value: truncate(highlighted_attrs, 1024),
          inline: false
        }
      ]
    else
      []
    end
  end

  # Helper functions

  defp build_mutamarket_url(nil), do: @mutamarket_base_url
  defp build_mutamarket_url(external_id), do: "#{@mutamarket_base_url}/#{external_id}"

  defp score_to_color(nil), do: @color_info

  defp score_to_color(score) when is_number(score) do
    cond do
      score >= 0.8 -> @color_excellent
      score >= 0.6 -> @color_good
      score >= 0.4 -> @color_moderate
      true -> @color_info
    end
  end

  defp score_to_color(_), do: @color_info

  defp format_price(nil), do: "N/A"

  defp format_price(%Decimal{} = price) do
    price
    |> Decimal.round(0)
    |> Decimal.to_string()
    |> format_number_with_commas()
    |> Kernel.<>(" ISK")
  end

  defp format_price(price) when is_number(price) do
    price
    |> round()
    |> Integer.to_string()
    |> format_number_with_commas()
    |> Kernel.<>(" ISK")
  end

  defp format_price(price) when is_binary(price), do: "#{price} ISK"
  defp format_price(_), do: "N/A"

  defp format_number_with_commas(number_string) do
    number_string
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp format_score(nil), do: "N/A"

  defp format_score(score) when is_number(score) do
    percentage = Float.round(score * 100, 1)
    "#{percentage}%"
  end

  defp format_score(_), do: "N/A"

  defp format_attribute_value(value) when is_float(value) do
    Float.round(value, 2) |> to_string()
  end

  defp format_attribute_value(value), do: to_string(value)

  defp truncate(string, max_length) when byte_size(string) <= max_length, do: string

  defp truncate(string, max_length) do
    String.slice(string, 0, max_length - 3) <> "..."
  end
end
