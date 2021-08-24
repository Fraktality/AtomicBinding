local CollectionService = game:GetService("CollectionService")

local ROOT_ALIAS = "root"

local function parsePath(pathStr)
	local pathArray = string.split(pathStr, "/")
	for idx = #pathArray, 1, -1 do
		if pathArray[idx] == "" then
			table.remove(pathArray, idx)
		end
	end
	return pathArray
end

local function isNodeBound(node)
	return node.instance ~= nil
end

local function isManifestResolved(resolvedManifest, manifestSizeTarget)
	local manifestSize = 0
	for _ in pairs(resolvedManifest) do
		manifestSize += 1
	end

	assert(manifestSize <= manifestSizeTarget, manifestSize)
	return manifestSize == manifestSizeTarget
end

local function unbindNodeDescend(node, resolvedManifest)
	if not isNodeBound(node) then
		return
	end

	node.instance = nil
	
	local connections = node.connections
	if connections then
		for _, conn in ipairs(connections) do
			conn:Disconnect()
		end
		table.clear(connections)
	end

	if resolvedManifest and node.alias then
		resolvedManifest[node.alias] = nil
	end

	local children = node.children
	if children then
		for _, childNode in pairs(children) do
			unbindNodeDescend(childNode, resolvedManifest)
		end
	end
end

local AtomicBinding = {}
AtomicBinding.__index = AtomicBinding

function AtomicBinding.new(tag, manifest, fn)
	debug.profilebegin("AtomicBinding.new")
	
	local connections = {} -- { Connection, ... }
	local dtorMap = {} -- { [root] -> dtor }
	local rootInstToRootNode = {} -- { [root] -> rootNode }
	local rootInstToManifest = {} -- { [root] -> { [alias] -> instance } }

	local manifestSizeTarget = 1 -- Start at 1 because root isn't explicitly on the manifest
	for _ in pairs(manifest) do
		manifestSizeTarget += 1
	end
	
	local function stopBoundFn(root)
		local dtor = dtorMap[root]
		if dtor then
			dtor:destroy()
			dtorMap[root] = nil
		end
	end
	
	local function startBoundFn(root, resolvedManifest)
		stopBoundFn(root)
		
		local dtor = fn(resolvedManifest)
		if dtor then
			dtorMap[root] = dtor
		end
	end
	
	local function bindRoot(root)
		assert(rootInstToManifest[root] == nil)
		
		local resolvedManifest = {}
		rootInstToManifest[root] = resolvedManifest
		
		debug.profilebegin("initializeBoundTree")
		
		local rootNode = {}
		rootNode.alias = ROOT_ALIAS
		rootNode.instance = root
		if next(manifest) then
			rootNode.children = {}
			rootNode.connections = {}
		end
		
		for alias, rawPath in pairs(manifest) do
			local parsedPath = parsePath(rawPath)
			local parentNode = rootNode
			
			for idx, childName in ipairs(parsedPath) do
				local leaf = idx == #parsedPath
				local childNode = parentNode.children[childName] or {}

				if leaf then
					if childNode.alias ~= nil then
						error("Multiple aliases assigned to one instance")
					end

					childNode.alias = alias
					
				else
					childNode.children = childNode.children or {}
					childNode.connections = childNode.connections or {}
				end

				parentNode.children[childName] = childNode
				parentNode = childNode
			end
		end
		
		debug.profileend()
		 
		-- Recursively descend into the tree, resolving each node.
		-- Nodes start out as empty and instance-less; the resolving process discovers instances to map to nodes.
		local function processNode(node)
			local instance = assert(node.instance)
			
			local children = node.children
			local alias = node.alias
			local isLeaf = not children
			
			if alias then
				resolvedManifest[alias] = instance
			end
			
			if not isLeaf then
				local function processAddChild(childInstance)
					local childName = childInstance.Name
					local childNode = children[childName]
					if not childNode or isNodeBound(childNode) then
						return
					end
					
					childNode.instance = childInstance
					processNode(childNode)
				end
				
				local function processDeleteChild(childInstance)
					-- Instance deletion - Parent A detects that child B is being removed
					--    1. A removes B from `children`
					--    2. A traverses down from B,
					--       i.  Disconnecting inputs
					--       ii. Removing nodes from the resolved manifest
					--    3. stopBoundFn is called because we know the tree is no longer complete, or at least has to be refreshed
					-- 	  4. We search A for a replacement for B, and attempt to re-resolve using that replacement if it exists.
					-- To support the above sanely, processAddChild needs to avoid resolving nodes that are already resolved.
					
					local childName = childInstance.Name
					local childNode = children[childName]
					
					if not childNode then
						return -- There's no child node corresponding to the deleted instance, ignore
					end
					
					if childNode.instance ~= childInstance then
						return -- A child was removed with the same name as a node instance, ignore
					end
					
					assert(isNodeBound(childNode)) -- If this triggers, processAddChild missed resolving a node
					
					stopBoundFn(root) -- Happens before the tree is unbound so the manifest is still valid in the destructor.
					unbindNodeDescend(childNode, resolvedManifest) -- Unbind the tree
					
					assert(not isNodeBound(childNode)) -- If this triggers, unbindNodeDescend failed
					
					-- Search for a replacement
					local replacementChild = instance:FindFirstChild(childName)
					if replacementChild then
						processAddChild(replacementChild)
					end
				end
				
				for _, child in ipairs(instance:GetChildren()) do
					processAddChild(child)
				end
				
				table.insert(node.connections, instance.ChildAdded:Connect(processAddChild))
				table.insert(node.connections, instance.ChildRemoved:Connect(processDeleteChild))
			end
			
			if isLeaf and isManifestResolved(resolvedManifest, manifestSizeTarget) then
				startBoundFn(root, resolvedManifest)
			end
		end
		
		debug.profilebegin("resolveBoundTree")
		processNode(rootNode)
		debug.profileend()
	end

	local function unbindRoot(root)
		stopBoundFn(root)
		
		local rootNode = rootInstToRootNode[root]
		if rootNode then
			local resolvedManifest = assert(rootInstToManifest[root])
			unbindNodeDescend(rootNode, resolvedManifest)
			rootInstToRootNode[root] = nil
		end
		
		rootInstToManifest[root] = nil
	end
	
	for _, rootInst in ipairs(CollectionService:GetTagged(tag)) do
		task.spawn(bindRoot, rootInst)
	end
	
	table.insert(connections, CollectionService:GetInstanceAddedSignal(tag):Connect(bindRoot))
	table.insert(connections, CollectionService:GetInstanceRemovedSignal(tag):Connect(unbindRoot))

	return setmetatable({
		_dtorMap = dtorMap,
		_connections = connections,
		_rootInstToRootNode = rootInstToRootNode,
		_rootInstToManifest = rootInstToManifest,
	}, AtomicBinding)
end

function AtomicBinding:destroy()
	debug.profilebegin("AtomicBinding:destroy")
	
	for _, dtor in pairs(self._dtorMap) do
		dtor:destroy()
	end
	table.clear(self._dtorMap)
	
	for _, conn in ipairs(self._connections) do
		conn:Disconnect()
	end
	table.clear(self._connections)
	
	local rootInstToManifest = self._rootInstToManifest
	for rootInst, rootNode in pairs(self._rootInstToRootNode) do
		local resolvedManifest = assert(rootInstToManifest[rootInst])
		unbindNodeDescend(rootNode, resolvedManifest)
	end
	table.clear(self._rootInstToManifest)
	table.clear(self._rootInstToRootNode)
	
	debug.profileend()
end

return AtomicBinding
