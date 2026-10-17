defmodule ITC.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/beardedeagle/itc_ex"

  def project do
    [
      # The OTP application is :itc_ex. Existing Erlang ITC packages on Hex
      # register an application named :itc, so that name would collide.
      app: :itc_ex,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      # Applies to this project only; Mix does not enforce it when the library
      # is compiled as someone else's dependency.
      elixirc_options: [warnings_as_errors: true],
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: "Interval Tree Clocks: causality tracking for dynamic systems.",
      package: package(),
      docs: docs(),
      source_url: @source_url,
      dialyzer: [
        plt_add_apps: [:ex_unit],
        # :missing_return and :underspecs only report Dialyzer widening the
        # recursive tree types (it cannot prove sums stay non-negative).
        flags: [:error_handling, :extra_return, :unmatched_returns]
      ]
    ]
  end

  def application, do: [extra_applications: []]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:stream_data, "~> 1.4", only: [:dev, :test]},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: "itc_ex",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Paper" => "https://gsd.di.uminho.pt/members/cbm/ps/itc2008.pdf"
      }
    ]
  end

  defp docs do
    [main: "ITC", extras: ["README.md"], source_ref: "v#{@version}"]
  end
end
