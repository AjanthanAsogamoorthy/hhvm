<?hh // strict
interface Rx1 {}

// ERROR: __OnlyRxIfImpl can only be put on methods
<<__Rx, __OnlyRxIfImpl(Rx1::class)>>
function mayberx(): void {
}
