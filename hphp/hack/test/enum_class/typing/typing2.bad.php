<?hh
// Copyright (c) Facebook, Inc. and its affiliates. All Rights Reserved.
<<file: __EnableUnstableFeatures('enum_class')>>

// User code
function expect_int(int $_): void {}
function expect_string(string $_): void {}
function expect_num(num $_): void {}

interface ExBox {}

class Box<T> implements ExBox {
  public function __construct(public T $data) {}
}

class IBox extends Box<int> {
  public function add(int $x): void {
    $this->data = $this->data + $x;
  }
}

abstract final class Helper {
  public static function ibox(): IBox {
    return new IBox(42);
  }
}

// Enum Class user code
enum class E: ExBox {
   Box<string> A = new Box('bli');
   IBox B = Helper::ibox();
   Box<int> B2 = new Box(42);
}

function generic<TEnum as E, T>(HH\MemberOf<TEnum, Box<T>> $param): T {
  return $param->data;
}

function testit2(): void {
  expect_string(generic(E::B)); // correctly errors, int vs string
}
