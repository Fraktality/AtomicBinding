# AtomicBinding
Atomically bind Lua code to a tagged tree of instances.
Uses concepts borrowed from [Destructor](https://github.com/Fraktality/Destructor).

# API
## `AtomicBinding.new`
```lua
AtomicBinding.new(
  tag: string,
  manifest: table,
  binding: function(objects: table),
)
```
Create a new atomic binding. Runs the `binding` function when all the instances of the tagged object exist. If the binding function returns a destructor, that destructor is called when the bound object is removed from the DataModel or if any/all of the objects in the manifest are removed from the tagged object.

Profiler label: `AtomicBinding.new`
## `AtomicBinding:destroy`
```lua
AtomicBinding:destroy()
```
Undoes the binding completely. Running bindings are cleanly destructed.

Profiler label: `AtomicBinding:destroy`
# Usage

```lua
local Destructor = require(Modules.Destructor)
local AtomicBinding = require(Modules.AtomicBinding)

return AtomicBinding.new("TestObject", { -- TestObject is a tag
	a = "A", -- A is a child of TestObject
	b = "B", -- B is a child of TestObject
	c = "B/C", -- C is a child of B
}, function(objects)
	local dtor = Destructor.new()
	
	print("Added")
	print("A:", objects.a)
	print("B:", objects.b)
	print("C:", objects.c)
	
	dtor:add(function()
		print("Removed")
	end)

	return dtor
end)
```
