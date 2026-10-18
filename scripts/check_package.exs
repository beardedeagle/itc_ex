# Run after `mix hex.build`: mix run --no-start scripts/check_package.exs
config = Mix.Project.config()
archive = ~c"#{config[:app]}-#{config[:version]}.tar"
{:ok, outer} = :erl_tar.extract(archive, [:memory])
{_, contents} = List.keyfind(outer, ~c"contents.tar.gz", 0)
{:ok, files} = :erl_tar.extract({:binary, contents}, [:compressed, :memory])

expected =
  Enum.sort(
    Path.wildcard("lib/**/*.ex") ++
      ["mix.exs", "README.md", "CHANGELOG.md", "LICENSE", ".formatter.exs"]
  )

actual = files |> Enum.map(fn {path, _} -> List.to_string(path) end) |> Enum.sort()

unless actual == expected do
  Mix.raise(
    "Unexpected package contents: missing #{inspect(expected -- actual)}, extra #{inspect(actual -- expected)}"
  )
end

for {path, bytes} <- files do
  unless bytes == File.read!(path), do: Mix.raise("Package differs from source: #{path}")
end

Mix.shell().info("Package contains exactly the intended source, documentation and license files.")
