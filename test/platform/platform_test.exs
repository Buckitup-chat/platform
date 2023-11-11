defmodule Platform.PlatformTest do
  use ExUnit.Case

  test "preparation" do
    cases = %{
      "simple list" => %{
        spec: [A, B, C],
        prepared: [A, B, C]
      },
      "simple list w/ params" => %{
        spec: [{A, b: 1}, B, C],
        prepared: [{A, b: 1}, B, C]
      },
      "one stage" => %{
        spec: [
          O,
          {:stage, First, {A, b: 1}},
          B,
          C
        ],
        prepared: [
          O,
          Platform.use_next_stage(Test.First, 10_000),
          {A, b: 1, next: [under: Test.First, run: [B, C]]}
        ]
      },
      "one stage, exit time set" => %{
        spec: [
          O,
          {:stage, First, {A, b: 1}},
          B,
          Platform.Storage.Bouncer |> Platform.exit_takes(10_000)
        ],
        prepared: [
          O,
          Platform.use_next_stage(Test.First, 15_000),
          {A,
           b: 1,
           next: [
             under: Test.First,
             run: [B, Platform.Storage.Bouncer |> Platform.exit_takes(10_000)]
           ]}
        ]
      },
      "two stages" => %{
        spec: [O, {:stage, First, {A, b: 1}}, B, C, {:stage, Second, {D, some: :arg}}, E, F],
        prepared: [
          O,
          Platform.use_next_stage(Test.First, 25_000),
          {A,
           b: 1,
           next: [
             under: Test.First,
             run: [
               B,
               C,
               Platform.use_next_stage(Test.Second, 10_000),
               {D, some: :arg, next: [under: Test.Second, run: [E, F]]}
             ]
           ]}
        ]
      },
      "step and stage" => %{
        spec: [O, {:step, First, {A, b: 1}}, B, C, {:stage, Second, {D, some: :arg}}, E, F],
        prepared: [
          O,
          {A,
           b: 1,
           next: [
             under: Test.First,
             run: [
               B,
               C,
               Platform.use_next_stage(Test.Second, 10_000),
               {D, some: :arg, next: [under: Test.Second, run: [E, F]]}
             ]
           ]},
          Platform.use_next_stage(Test.First, 25_000)
        ]
      },
      "one step, no tail" => %{
        spec: [O, {:step, First, {A, b: 1}}],
        prepared: [
          O,
          {A, b: 1}
        ]
      },
      "one stage, no tail" => %{
        spec: [O, {:stage, First, {A, b: 1}}],
        prepared: [
          O,
          {A, b: 1}
        ]
      },
      "one virtual stage" => %{
        spec: [O, {:stage, First, A}],
        prepared: [O, A]
      },
      "empty" => %{
        spec: [],
        prepared: []
      },
      "one virtual stage" => %{
        spec: [O, {:stage, First, A},{:step, Second, B}, C],
        prepared: [
          O,
          %{
            id: Test.First,
            shutdown: 10000,
            start: {DynamicSupervisor, :start_link,
              [[name: Test.First, strategy: :one_for_one, max_restarts: 0]]},
            type: :supervisor
          },
          {A,
            [
              next: [
                under: Test.First,
                run: [
                  {B, [next: [under: Test.Second, run: [C]]]},
                  %{
                    id: Test.Second,
                    shutdown: 5000,
                    start: {DynamicSupervisor, :start_link,
                      [[name: Test.Second, strategy: :one_for_one, max_restarts: 0]]},
                    type: :supervisor
                  }
                ]
              ]
            ]}
        ]
      },

    }

    for {title, %{spec: spec, prepared: prepared}} <- cases do
      processed = Platform.prepare_stages(spec, Test)

      assert processed == prepared, """
      #{title}
        #{diff(processed |> inspect(pretty: true), prepared |> inspect(pretty: true))}
      """
    end
  end

  defp diff(a, b) do
    String.myers_difference(a, b)
    |> Enum.map(fn
      {:eq, part} -> IO.ANSI.cyan() <> part <> IO.ANSI.default_color()
      {:del, part} -> IO.ANSI.red() <> part <> IO.ANSI.default_color()
      {:ins, part} -> IO.ANSI.green() <> part <> IO.ANSI.default_color()
    end)
  end
end
