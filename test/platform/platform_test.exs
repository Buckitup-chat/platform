defmodule PlatformTest do
  use ExUnit.Case

  test "preparation" do
    cases = %{
      [A, B, C] => [A, B, C],
      [{A, b: 1}, B, C] => [{A, b: 1}, B, C],
      [
        O,
        {:stage, First, {A, b: 1}},
        B,
        C
      ] => [
        O,
        Platform.use_next_stage(Test.First, 10_000),
        {A,
         b: 1,
         next: [
           under: Test.First,
           run: [
             B,
             C
           ]
         ]}
      ],
      [O, {:stage, First, {A, b: 1}}] => [
        O,
        {A, b: 1}
      ],
      [O, {:stage, First, {A, b: 1}}, B, C, {:stage, Second, {D, some: :arg}}, E, F] => [
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
    }

    for {spec, expected} <- cases do
      assert Platform.prepare_stages(spec, Test) == expected
    end
  end
end
