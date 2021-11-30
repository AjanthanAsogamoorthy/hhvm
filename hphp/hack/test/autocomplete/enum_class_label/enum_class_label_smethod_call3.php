<?hh

enum class E : mixed {
  int A = 42;
}

class C {
  static public function g<T>(HH\EnumClass\Label<E, T> $label) : T {
    return E::valueOf($label);
  }
}

<<__EntryPoint>>
function main(): void {
  C::g<int>#AUTO332
}
