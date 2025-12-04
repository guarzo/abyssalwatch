defmodule Abyssalwatch.Fittings.Parsers.XML do
  @moduledoc """
  Parser and encoder for EVE XML fitting format.

  Used for file import/export, supports multiple fittings per file.

  ## XML Format

  The standard EVE fitting XML format:

  ```xml
  <?xml version="1.0"?>
  <fittings>
    <fitting name="My Fit">
      <description value="A description"/>
      <shipType value="Vexor Navy Issue"/>
      <hardware slot="low slot 0" type="Damage Control II"/>
      <hardware slot="med slot 0" type="10MN Afterburner II"/>
      <hardware slot="hi slot 0" type="Medium Energy Neutralizer II"/>
      <hardware slot="rig slot 0" type="Medium Auxiliary Nano Pump I"/>
      <hardware qty="5" slot="drone bay" type="Hobgoblin II"/>
      <hardware slot="cargo" type="Nanite Repair Paste" qty="100"/>
    </fitting>
  </fittings>
  ```

  ## Slot Naming Convention

  - Low slots: "low slot 0", "low slot 1", etc.
  - Medium slots: "med slot 0", "med slot 1", etc.
  - High slots: "hi slot 0", "hi slot 1", etc.
  - Rig slots: "rig slot 0", "rig slot 1", etc.
  - Subsystems: "subsystem slot 0", etc.
  - Drone bay: "drone bay"
  - Cargo: "cargo"
  """

  require Logger

  @doc """
  Parse XML fitting file content. Returns list of fittings.

  Accepts both single <fitting> elements and <fittings> containers.
  """
  @spec parse(String.t()) :: {:ok, list(map())} | {:error, String.t()}
  def parse(nil), do: {:error, "XML content cannot be nil"}
  def parse(""), do: {:error, "XML content cannot be empty"}

  def parse(xml_content) when is_binary(xml_content) do
    case parse_xml_document(xml_content) do
      {:ok, fittings} -> {:ok, fittings}
      {:error, reason} -> {:error, reason}
    end
  end

  def parse(_), do: {:error, "Invalid input type"}

  @doc """
  Parse a single fitting from XML string.
  """
  @spec parse_single(String.t()) :: {:ok, map()} | {:error, String.t()}
  def parse_single(xml_content) do
    case parse(xml_content) do
      {:ok, [fitting | _]} -> {:ok, fitting}
      {:ok, []} -> {:error, "No fittings found in XML"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Encode fittings to XML format.

  Accepts either a single fitting map or a list of fittings.
  """
  @spec encode(map() | list(map())) :: String.t()
  def encode(fittings) when is_list(fittings) do
    fitting_elements =
      fittings
      |> Enum.map(&encode_fitting/1)
      |> Enum.join("\n")

    """
    <?xml version="1.0"?>
    <fittings>
    #{fitting_elements}
    </fittings>
    """
    |> String.trim()
  end

  def encode(fitting) when is_map(fitting), do: encode([fitting])

  @doc """
  Encode a single fitting to XML (without the <fittings> wrapper).
  """
  @spec encode_single(map()) :: String.t()
  def encode_single(fitting) do
    encode_fitting(fitting)
  end

  # Private functions - XML Parsing

  defp parse_xml_document(content) do
    # Clean up the content
    content = String.trim(content)

    try do
      # Use Erlang's xmerl for XML parsing
      {doc, _rest} = :xmerl_scan.string(String.to_charlist(content), quiet: true)
      fittings = extract_fittings_from_doc(doc)
      {:ok, fittings}
    rescue
      e ->
        Logger.warning("XML parsing failed: #{inspect(e)}")
        {:error, "Invalid XML format: #{Exception.message(e)}"}
    catch
      :exit, reason ->
        Logger.warning("XML parsing exit: #{inspect(reason)}")
        {:error, "XML parsing failed"}
    end
  end

  defp extract_fittings_from_doc(doc) do
    # Try to find <fitting> elements anywhere in the document
    fitting_elements = find_fitting_elements(doc)

    Enum.map(fitting_elements, &parse_fitting_element/1)
  end

  defp find_fitting_elements(doc) do
    # Use XPath to find all fitting elements
    try do
      :xmerl_xpath.string(~c"//fitting", doc)
    rescue
      _ -> []
    catch
      _, _ -> []
    end
  end

  defp parse_fitting_element(fitting_elem) do
    name = get_xml_attribute(fitting_elem, ~c"name") || "Unnamed"
    description = get_child_element_value(fitting_elem, ~c"description")
    ship_type = get_child_element_value(fitting_elem, ~c"shipType")
    hardware = get_hardware_elements(fitting_elem)

    %{
      name: name,
      description: description,
      ship_type: ship_type,
      low_slots: filter_hardware_by_slot(hardware, "low slot"),
      med_slots: filter_hardware_by_slot(hardware, "med slot"),
      high_slots: filter_hardware_by_slot(hardware, "hi slot"),
      rig_slots: filter_hardware_by_slot(hardware, "rig slot"),
      subsystems: filter_hardware_by_slot(hardware, "subsystem slot"),
      drones: filter_hardware_by_slot(hardware, "drone bay"),
      cargo: filter_hardware_by_slot(hardware, "cargo")
    }
  end

  defp get_xml_attribute(element, attr_name) do
    case element do
      {:xmlElement, _name, _expanded, _nsinfo, _namespace, _parents, _pos, attributes, _content,
       _language, _xmlbase, _elementdef} ->
        find_attribute_value(attributes, attr_name)

      _ ->
        nil
    end
  end

  defp find_attribute_value(attributes, name) when is_list(attributes) do
    Enum.find_value(attributes, fn
      {:xmlAttribute, ^name, _expanded, _nsinfo, _namespace, _parents, _pos, _language, value,
       _normalized} ->
        to_string(value)

      _ ->
        nil
    end)
  end

  defp find_attribute_value(_, _), do: nil

  defp get_child_element_value(parent, child_name) do
    case parent do
      {:xmlElement, _name, _expanded, _nsinfo, _namespace, _parents, _pos, _attributes, content,
       _language, _xmlbase, _elementdef} ->
        find_child_value(content, child_name)

      _ ->
        nil
    end
  end

  defp find_child_value(content, name) when is_list(content) do
    Enum.find_value(content, fn
      {:xmlElement, ^name, _expanded, _nsinfo, _namespace, _parents, _pos, attributes, _content,
       _language, _xmlbase, _elementdef} ->
        find_attribute_value(attributes, ~c"value")

      _ ->
        nil
    end)
  end

  defp find_child_value(_, _), do: nil

  defp get_hardware_elements(parent) do
    case parent do
      {:xmlElement, _name, _expanded, _nsinfo, _namespace, _parents, _pos, _attributes, content,
       _language, _xmlbase, _elementdef} ->
        extract_hardware_from_content(content)

      _ ->
        []
    end
  end

  defp extract_hardware_from_content(content) when is_list(content) do
    Enum.flat_map(content, fn
      {:xmlElement, :hardware, _expanded, _nsinfo, _namespace, _parents, _pos, attributes,
       _content, _language, _xmlbase, _elementdef} ->
        slot = find_attribute_value(attributes, ~c"slot") || ""
        type = find_attribute_value(attributes, ~c"type") || ""
        qty = parse_quantity(find_attribute_value(attributes, ~c"qty"))

        [%{slot: slot, type: type, quantity: qty}]

      _ ->
        []
    end)
  end

  defp extract_hardware_from_content(_), do: []

  defp parse_quantity(nil), do: 1
  defp parse_quantity(""), do: 1

  defp parse_quantity(qty_str) do
    case Integer.parse(qty_str) do
      {qty, ""} -> qty
      _ -> 1
    end
  end

  defp filter_hardware_by_slot(hardware, slot_prefix) do
    hardware
    |> Enum.filter(fn hw ->
      String.starts_with?(hw.slot, slot_prefix) or hw.slot == slot_prefix
    end)
    |> Enum.map(fn hw ->
      %{
        name: hw.type,
        quantity: hw.quantity
      }
    end)
  end

  # Private functions - XML Encoding

  defp encode_fitting(fitting) do
    name = escape_xml(fitting[:name] || fitting["name"] || "Unnamed")
    description = escape_xml(fitting[:description] || fitting["description"] || "")
    ship_type = escape_xml(fitting[:ship_type] || fitting["ship_type"] || "")

    hardware_lines =
      [
        encode_slot_hardware(fitting[:low_slots] || fitting["low_slots"], "low slot"),
        encode_slot_hardware(fitting[:med_slots] || fitting["med_slots"], "med slot"),
        encode_slot_hardware(fitting[:high_slots] || fitting["high_slots"], "hi slot"),
        encode_slot_hardware(fitting[:rig_slots] || fitting["rig_slots"], "rig slot"),
        encode_slot_hardware(fitting[:subsystems] || fitting["subsystems"], "subsystem slot"),
        encode_bay_hardware(fitting[:drones] || fitting["drones"], "drone bay"),
        encode_bay_hardware(fitting[:cargo] || fitting["cargo"], "cargo")
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&("    " <> &1))
      |> Enum.join("\n")

    """
      <fitting name="#{name}">
        <description value="#{description}"/>
        <shipType value="#{ship_type}"/>
    #{hardware_lines}
      </fitting>
    """
  end

  defp encode_slot_hardware(nil, _slot_prefix), do: []
  defp encode_slot_hardware([], _slot_prefix), do: []

  defp encode_slot_hardware(modules, slot_prefix) when is_list(modules) do
    modules
    |> Enum.with_index()
    |> Enum.flat_map(fn {module, idx} ->
      name = get_module_name(module)
      qty = get_module_quantity(module)
      slot = "#{slot_prefix} #{idx}"

      # For modules with quantity > 1, create multiple entries (one per slot)
      # But for most slot modules, quantity should be 1
      if qty > 1 do
        Enum.map(0..(qty - 1), fn i ->
          ~s(<hardware slot="#{slot_prefix} #{idx + i}" type="#{escape_xml(name)}"/>)
        end)
      else
        [~s(<hardware slot="#{slot}" type="#{escape_xml(name)}"/>)]
      end
    end)
  end

  defp encode_bay_hardware(nil, _bay), do: []
  defp encode_bay_hardware([], _bay), do: []

  defp encode_bay_hardware(items, bay) when is_list(items) do
    Enum.map(items, fn item ->
      name = get_module_name(item)
      qty = get_module_quantity(item)

      if qty > 1 do
        ~s(<hardware slot="#{bay}" type="#{escape_xml(name)}" qty="#{qty}"/>)
      else
        ~s(<hardware slot="#{bay}" type="#{escape_xml(name)}"/>)
      end
    end)
  end

  defp get_module_name(%{name: name}), do: name
  defp get_module_name(%{"name" => name}), do: name
  defp get_module_name(name) when is_binary(name), do: name
  defp get_module_name(_), do: ""

  defp get_module_quantity(%{quantity: qty}), do: qty
  defp get_module_quantity(%{"quantity" => qty}), do: qty
  defp get_module_quantity(_), do: 1

  defp escape_xml(nil), do: ""

  defp escape_xml(str) when is_binary(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp escape_xml(other), do: escape_xml(to_string(other))
end
