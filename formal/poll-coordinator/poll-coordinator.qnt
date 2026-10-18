// Host-only polling contract. Each transition is one API event followed by a
// microtask checkpoint. The poll adapter starts an idle loop synchronously;
// unrelated LuCI poll entries and timer ticks are outside this pilot.
module poll_coordinator {
  type State = {
    epoch: int, hidden: bool, rememberedHidden: bool, started: bool,
    disposed: bool, registered: bool, cadence: int,
    active: int, activeEpoch: int, pending: int, nextId: int,
    starts: int, visible: int, settled: Set[int], returned: int
  }
  var s: State
  var event: str
  var argument: int
  var count: int

  pure val initial = {
    epoch: 0, hidden: false, rememberedHidden: false, started: false,
    disposed: false, registered: false, cadence: 1,
    active: 0, activeEpoch: 0, pending: 0, nextId: 1,
    starts: 0, visible: 0, settled: Set(), returned: -2
  }

  pure def launch(x: State): State = {
    ...x, active: x.pending, activeEpoch: x.epoch, pending: 0,
    starts: x.starts + 1
  }
  pure def request(x: State): State = {
    if (x.disposed or x.hidden) { ...x, returned: -1 }
    else {
      val q = if (x.pending == 0)
        { ...x, pending: x.nextId, nextId: x.nextId + 1 }
        else x
      val r = { ...q, returned: q.pending }
      if (r.active == 0) launch(r) else r
    }
  }
  pure def catchUp(x: State): State = {
    if (x.disposed or x.hidden) { ...x, returned: -1 }
    else if (x.active != 0 and x.activeEpoch == x.epoch and x.pending == 0)
      { ...x, returned: x.active }
    else request(x)
  }
  pure def register(x: State): State = {
    if (x.started and not(x.disposed) and not(x.hidden) and not(x.registered))
      request({ ...x, registered: true })
    else x
  }
  pure def start(x: State): State = {
    if (x.started or x.disposed) x
    else register({ ...x, started: true, rememberedHidden: x.hidden })
  }
  pure def visibility(x: State, hidden: bool): State = {
    val y = { ...x, hidden: hidden }
    if (not(x.started) or x.disposed or x.rememberedHidden == hidden) y
    else {
      val z = { ...y, epoch: x.epoch + 1, rememberedHidden: hidden }
      if (hidden) { ...z, registered: false }
      else catchUp(register({ ...z, visible: z.visible + 1 }))
    }
  }
  pure def complete(x: State): State = {
    if (x.active == 0) x
    else {
      val y = { ...x, active: 0, settled: x.settled.union(Set(x.active)) }
      if (y.pending != 0 and not(y.hidden)) launch(y) else y
    }
  }
  pure def dispose(x: State): State = {
    if (x.disposed) x
    else {
      ...x, disposed: true, epoch: x.epoch + 1, registered: false,
      active: 0, pending: 0,
      settled: x.settled.union(Set(x.active, x.pending).exclude(Set(0)))
    }
  }
  pure def apply(x: State, command: str, arg: int): State = {
    val y = { ...x, returned: -2 }
    val z = if (command == "request") request(y)
      else if (command == "catchUp") catchUp(y)
      else if (command == "start") start(y)
      else if (command == "hide") visibility(y, true)
      else if (command == "show") visibility(y, false)
      else if (command == "resolve" or command == "reject") complete(y)
      else if (command == "cadence" and not(y.disposed)) { ...y, cadence: arg }
      else if (command == "dispose") dispose(y)
      else y
    // Only explicit API request/catchUp return a tracked promise to the driver.
    if (command == "request" or command == "catchUp") z
    else { ...z, returned: -2 }
  }
  action init = all {
    s' = initial, event' = "init", argument' = 1, count' = 0
  }
  action choose(choices: Set[str]): bool = {
    nondet command = choices.oneOf()
    nondet cadence = Set(1, 5).oneOf()
    all {
      s' = apply(s, command, cadence), event' = command, argument' = cadence,
      count' = count + 1
    }
  }
  action move = choose(Set("request", "catchUp", "start", "hide", "show",
    "resolve", "reject", "cadence", "dispose"))
  action step = all { count < 30, move }
  // Directed traces use the same apply relation, never hand-written expected states.
  pure val edges = List(
    List("start", "catchUp", "request", "request", "resolve", "reject", "dispose", "request"),
    List("hide", "start", "request", "show", "resolve", "dispose", "show", "request"),
    List("start", "hide", "show", "request", "cadence", "resolve", "resolve", "dispose"),
    List("request", "hide", "resolve", "show", "start", "cadence", "dispose", "resolve"),
    List("request", "request", "dispose", "resolve", "reject", "start", "request", "catchUp"),
    List("start", "cadence", "catchUp", "resolve", "hide", "show", "resolve", "dispose"),
    List("start", "hide", "request", "show", "reject", "resolve", "dispose", "catchUp")
  )
  action directed(index: int): bool = all {
    count < edges.nth(index).length(), choose(Set(edges.nth(index).nth(count)))
  }
  action edge0 = directed(0)
  action edge1 = directed(1)
  action edge2 = directed(2)
  action edge3 = directed(3)
  action edge4 = directed(4)
  action edge5 = directed(5)
  action edge6 = directed(6)
  // Exhaustive bounded model check; separate from the 30-event MBT samples.
  action checkStep = all { count < 5, move }
  val invariant = all {
    s.active >= 0, s.pending >= 0, s.nextId > s.active,
    s.nextId > s.pending, s.active == 0 or s.active != s.pending,
    s.active == 0 or not(s.settled.contains(s.active)),
    s.pending == 0 or not(s.settled.contains(s.pending)),
    not(s.disposed) or (s.active == 0 and s.pending == 0 and not(s.registered)),
    not(s.registered) or (s.started and not(s.hidden) and not(s.disposed)),
    s.cadence == 1 or s.cadence == 5
  }
}
