defmodule ITC.Generators do
  @moduledoc "StreamData generators for normalized ITC trees and stamps."

  use ExUnitProperties

  alias ITC.{Event, Id}

  @doc "Any normalized id tree, including 0."
  def id_tree do
    tree(member_of([0, 1]), fn child -> tuple({child, child}) end)
    |> map(&Id.normalize/1)
    |> scale(&min(&1, 24))
  end

  @doc "A normalized id tree that owns something."
  def owning_id do
    map(id_tree(), fn
      0 -> 1
      id -> id
    end)
  end

  @doc "Any normalized event tree."
  def event_tree do
    tree(integer(0..4), fn child -> tuple({integer(0..3), child, child}) end)
    |> map(&Event.normalize/1)
    |> scale(&min(&1, 24))
  end

  @doc "Two disjoint, owning ids carved out of one owning id."
  def disjoint_ids do
    gen all(
          id <- owning_id(),
          left_depth <- integer(0..2),
          right_depth <- integer(0..2),
          picks <- list_of(boolean(), length: 4)
        ) do
      {a, b} = Id.split(id)
      {shrink(a, left_depth, Enum.take(picks, 2)), shrink(b, right_depth, Enum.drop(picks, 2))}
    end
  end

  defp shrink(id, 0, _picks), do: id

  defp shrink(id, depth, [pick | picks]) do
    {l, r} = Id.split(id)
    shrink(if(pick, do: l, else: r), depth - 1, picks ++ [pick])
  end

  @doc "A valid stamp."
  def stamp do
    gen all(id <- id_tree(), event <- event_tree()) do
      {:ok, stamp} = ITC.new(id, event)
      stamp
    end
  end

  @doc "A valid stamp that can record events."
  def owning_stamp do
    gen all(id <- owning_id(), event <- event_tree()) do
      {:ok, stamp} = ITC.new(id, event)
      stamp
    end
  end
end
