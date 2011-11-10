# Copyright (C) 2011 Jacob Beard
# Released under GNU LGPL, read the file 'COPYING' for more information

define ["util/set/ArraySet","scxml/state-kinds-enum","scxml/event","util/reduce","scxml/setup-default-opts"],(ArraySet,stateKinds,Event,reduce,setupDefaultOpts) ->

	#imports

	flatten = (l) ->
		a = []
		for list in l
			a = a.concat(list)

		return a


	#technique adapted from http://javascript.crockford.com/prototypal.html
	create = (o) ->
		if Object.create
			Object.create(o)
		else
			F = ->
			F.prototype = o
			return new F()

	# -> Priority: Source-Child 
	getTransitionWithHigherSourceChildPriority = (model) ->
		([t1,t2]) ->
			"""
			compare transitions based first on depth, then based on document order
			"""
			if model.getDepth(t1.source) < model.getDepth(t2.source)
				return t2
			else if model.getDepth(t2.source) < model.getDepth(t1.source)
				return t1
			else
				if t1.documentOrder < t2.documentOrder
					return t1
				else
					return t2

	class SCXMLInterpreter

		constructor : (@model,@opts={}) ->

			if @opts.printTrace
				console.debug "initializing SCXML interpreter with opts:"
				for own k,v of opts
					v = if typeof v is "function" then v.toString() else v
					console.debug k,v

			#default args
			#@opts.onlySelectFromBasicStates
			#@opts.printTrace = true
			#@opts.evaluationContext	#sets the this object for script evaluation
			#@opts.transitionSelector ?= defaultTransitionSelector()
			#@opts.model ?= m
			#@opts.TransitionSet ?= ArraySet
			#@opts.StateSet ?= ArraySet
			#@opts.BasicStateSet ?= ArraySet
			@opts.StateIdSet ?= ArraySet
			@opts.EventSet ?= ArraySet
			@opts.TransitionPairSet ?= ArraySet
			@opts.priorityComparisonFn ?= getTransitionWithHigherSourceChildPriority(@opts.model)
			@opts.globalEval ?= window?.executeScript or eval		#we parameterize this in case we want to use, e.g. jquery.globalEval

			@_configuration = new @opts.BasicStateSet()	#full configuration, or basic configuration? what kind of set implementation?
			@_historyValue = {}
			@_innerEventQueue = []
			@_isInFinalState = false
			@_datamodel = create @model.datamodel		#FIXME: should these be global, or declared at the level of the big step, like the eventQueue?
			@_timeoutMap = {}

		
		start: ->
			#perform big step without events to take all default transitions and reach stable initial state
			if @opts.printTrace then console.debug("performing initial big step")
			@_configuration.add(@model.root.initial)

			#eval top-level scripts
			#we treat these differently than other scripts. they get evaled in global scope, and without explicit scripting interface
			#this is necessary in order to, e.g., allow js function declarations that are visible to scxml script tags later.
			for script in @model.scripts
				`with(this._datamodel){ this.opts.globalEval.call(null,script) }`

			#initialize top-level datamodel expressions. simple eval
			for k,v of @_datamodel
				if v then @_datamodel[k] = eval(v)

			@_performBigStep()

		getConfiguration: -> new @opts.StateIdSet(s.id for s in @_configuration.iter())

		getFullConfiguration: -> new @opts.StateIdSet(s.id for s in (flatten([s].concat @opts.model.getAncestors(s) for s in @_configuration.iter())))

		isIn: (stateName) -> @getFullConfiguration().contains(stateName)

		_performBigStep: (e) ->
			if e then @_innerEventQueue.push(new @opts.EventSet([e]))

			keepGoing = true

			while keepGoing
				eventSet = if @_innerEventQueue.length then @_innerEventQueue.shift() else new @opts.EventSet()

				#create new datamodel cache for the next small step
				datamodelForNextStep = {}

				selectedTransitions = @_performSmallStep(eventSet,datamodelForNextStep)

				keepGoing = not selectedTransitions.isEmpty()

			nonFinalStates = (s for s of @_configuration.iter() when s.kind is not stateKinds.FINAL)

			if nonFinalStates.length is 0
				@_isInFinalState = true

		_performSmallStep: (eventSet,datamodelForNextStep) ->

			if @opts.printTrace then console.debug("selecting transitions with eventSet: " , eventSet)

			selectedTransitions = @_selectTransitions(eventSet,datamodelForNextStep)

			if @opts.printTrace then console.debug("selected transitions: " , selectedTransitions)

			if selectedTransitions

				if @opts.printTrace then console.debug("sorted transitions: ", selectedTransitions)

				[basicStatesExited,statesExited] = @_getStatesExited(selectedTransitions)
				[basicStatesEntered,statesEntered] = @_getStatesEntered(selectedTransitions)

				if @opts.printTrace then console.debug("basicStatesExited " , basicStatesExited)
				if @opts.printTrace then console.debug("basicStatesEntered " , basicStatesEntered)
				if @opts.printTrace then console.debug("statesExited " , statesExited)
				if @opts.printTrace then console.debug("statesEntered " , statesEntered)

				eventsToAddToInnerQueue = new @opts.EventSet()

				#operations will be performed in the order described in Rhapsody paper

				#update history states

				if @opts.printTrace then console.debug("executing state exit actions")
				for state in statesExited
					if @opts.printTrace then console.debug("exiting " , state)

					#peform exit actions
					for action in state.onexit
						@_evaluateAction(action,eventSet,datamodelForNextStep,eventsToAddToInnerQueue)

					#update history
					if state.history
						if state.history.isDeep
							f = (s0) => s0.kind is stateKinds.BASIC and s0 in @opts.model.getDescendants(state)
						else
							f = (s0) -> s0.parent is state
						
						@_historyValue[state.history.id] = (s for s in statesExited when f(s))

				# -> Concurrency: Number of transitions: Multiple
				# -> Concurrency: Order of transitions: Explicitly defined
				sortedTransitions = selectedTransitions.iter().sort( (t1,t2) -> t1.documentOrder - t2.documentOrder)

				if @opts.printTrace then console.debug("executing transitition actions")
				for transition in sortedTransitions
					if @opts.printTrace then console.debug("transitition " , transition)
					for action in transition.actions
						@_evaluateAction(action,eventSet,datamodelForNextStep,eventsToAddToInnerQueue)

				if @opts.printTrace then console.debug("executing state enter actions")
				for state in statesEntered
					if @opts.printTrace then console.debug("entering " , state)
					for action in state.onentry
						@_evaluateAction(action,eventSet,datamodelForNextStep,eventsToAddToInnerQueue)

				#update configuration by removing basic states exited, and adding basic states entered
				if @opts.printTrace then console.debug("updating configuration ")
				if @opts.printTrace then console.debug("old configuration " , @_configuration)

				@_configuration.difference basicStatesExited
				@_configuration.union basicStatesEntered

				if @opts.printTrace then console.debug("new configuration " , @_configuration)
				
				#add set of generated events to the innerEventQueue -> Event Lifelines: Next small-step
				if not eventsToAddToInnerQueue.isEmpty()
					if @opts.printTrace then console.debug("adding triggered events to inner queue " , eventsToAddToInnerQueue)

					@_innerEventQueue.push(eventsToAddToInnerQueue)

				#update the datamodel
				if @opts.printTrace then console.debug("updating datamodel for next small step :")
				for own key of datamodelForNextStep
					if @opts.printTrace then console.debug("key " , key)
					if key of @_datamodel
						if @opts.printTrace then console.debug("old value " , @_datamodel[key])
					else
						if @opts.printTrace then console.debug("old value is null")
					if @opts.printTrace then console.debug("new value " , datamodelForNextStep[key])
						
					@_datamodel[key] = datamodelForNextStep[key]

			#if selectedTransitions is empty, we have reached a stable state, and the big-step will stop, otherwise will continue -> Maximality: Take-Many
			return selectedTransitions


		_evaluateAction: (action,eventSet,datamodelForNextStep,eventsToAddToInnerQueue) ->
			switch action.type
				when "send"
					if @opts.printTrace then console.debug "sending event",action.event,"with content",action.contentexpr
					data = if action.contentexpr then @_eval action,datamodelForNextStep,eventSet else null

					eventsToAddToInnerQueue.add new Event action.event,data
				when "assign"
					datamodelForNextStep[action.location] = @_eval action,datamodelForNextStep,eventSet
				when "script"
					@_eval action,datamodelForNextStep,eventSet,true
				when "log"
					log = @_eval action,datamodelForNextStep,eventSet
					if @opts.printTrace then console.log(log)	#the one place where we use straight console.log

		_eval : (action,datamodelForNextStep,eventSet,allowWrite) ->
			#get the scripting interface
			n = @_getScriptingInterface(datamodelForNextStep,eventSet,allowWrite)

			action.evaluate.call(@opts.evaluationContext,n.getData,n.setData,n.In,n.events,@_datamodel)

		_getScriptingInterface: (datamodelForNextStep,eventSet,allowWrite=false) ->
			setData : if allowWrite then (name,value) -> datamodelForNextStep[name] = value else ->
			getData : (name) => @_datamodel[name]
			In : (s) => @isIn(s)
			events : eventSet.iter()

		_getStatesExited: (transitions) ->
			statesExited = new @opts.StateSet()
			basicStatesExited = new @opts.BasicStateSet()

			for transition in transitions.iter()
				lca = @opts.model.getLCA(transition)
				desc = @opts.model.getDescendants(lca)
			
				for state in @_configuration.iter()
					if state in desc
						basicStatesExited.add(state)
						statesExited.add(state)
						for anc in @opts.model.getAncestors(state,lca)
							statesExited.add(anc)

			sortedStatesExited = statesExited.iter().sort((s1,s2) =>  @opts.model.getDepth(s2) - @opts.model.getDepth(s1))

			return [basicStatesExited,sortedStatesExited]

		_getStatesEntered: (transitions) ->
			statesToRecursivelyAdd = flatten((state for state in transition.targets) for transition in transitions.iter())
			if @opts.printTrace then console.debug "statesToRecursivelyAdd :",statesToRecursivelyAdd
			statesToEnter = new @opts.StateSet()
			basicStatesToEnter = new @opts.BasicStateSet()

			while statesToRecursivelyAdd.length
				for state in statesToRecursivelyAdd
					@_recursiveAddStatesToEnter(state,statesToEnter,basicStatesToEnter)
				
				statesToRecursivelyAdd = @_getChildrenOfParallelStatesWithoutDescendantsInStatesToEnter(statesToEnter)

			sortedStatesEntered = statesToEnter.iter().sort((s1,s2) => @opts.model.getDepth(s1) - @opts.model.getDepth(s2))

			return [basicStatesToEnter,sortedStatesEntered]

		_getChildrenOfParallelStatesWithoutDescendantsInStatesToEnter: (statesToEnter) ->
			childrenOfParallelStatesWithoutDescendantsInStatesToEnter = new @opts.StateSet()

			#get all descendants of states to enter
			descendantsOfStatesToEnter = new @opts.StateSet()
			for state in statesToEnter.iter()
				for descendant in @opts.model.getDescendants(state)
					descendantsOfStatesToEnter.add(descendant)

			for state in statesToEnter.iter()
				if state.kind is stateKinds.PARALLEL
					for child in state.children
						if not descendantsOfStatesToEnter.contains(child)
							childrenOfParallelStatesWithoutDescendantsInStatesToEnter.add(child)

			return childrenOfParallelStatesWithoutDescendantsInStatesToEnter
				

		_recursiveAddStatesToEnter: (s,statesToEnter,basicStatesToEnter) ->
			if s.kind is stateKinds.HISTORY
				if s.id of @_historyValue
					for historyState in @_historyValue[s.id]
						@_recursiveAddStatesToEnter(historyState,statesToEnter,basicStatesToEnter)
				else
					statesToEnter.add(s)
					basicStatesToEnter.add(s)
			else
				statesToEnter.add(s)

				if s.kind is stateKinds.PARALLEL
					for child in s.children
						if not (child.kind is stateKinds.HISTORY)		#don't enter history by default
							@_recursiveAddStatesToEnter(child,statesToEnter,basicStatesToEnter)

				else if s.kind is stateKinds.COMPOSITE

					#FIXME: problem: this doesn't check cond of initial state transitions
					#also doesn't check priority of transitions (problem in the SCXML spec?)
					#TODO: come up with test case that shows other is broken
					#what we need to do here: select transitions...
					#for now, make simplifying assumption. later on check cond, then throw into the parameterized choose by priority
					@_recursiveAddStatesToEnter(s.initial,statesToEnter,basicStatesToEnter)

				else if s.kind is stateKinds.INITIAL or s.kind is stateKinds.BASIC or s.kind is stateKinds.FINAL
					basicStatesToEnter.add(s)

			
		_selectTransitions: (eventSet,datamodelForNextStep) ->

			if @opts.onlySelectFromBasicStates
				states = @_configuration.iter()
			else
				statesAndParents = new @opts.StateSet

				#get full configuration, unordered
				#this means we may select transitions from parents before children
				for basicState in @_configuration.iter()
					statesAndParents.add(basicState)

					for ancestor in @opts.model.getAncestors(basicState)
						statesAndParents.add(ancestor)

				states = statesAndParents.iter()

			n = @_getScriptingInterface(datamodelForNextStep,eventSet)
			e = (t) => t.evaluateCondition.call(@opts.evaluationContext,n.getData,n.setData,n.In,n.events,@_datamodel)

			eventNames = (event.name for event in eventSet.iter())

			#debugger
			allTransitionsForEachState = (new @opts.TransitionSet @opts.transitionSelector state,eventNames,e for state in states)

			if @opts.printTrace then console.debug("allTransitionsForEachState",allTransitionsForEachState)
			consistentTransitions = @_makeTransitionsConsistent reduce((@_makeTransitionsConsistent transitionSet for transitionSet in allTransitionsForEachState),((a,b) -> a.union b), new @opts.TransitionSet)
			if @opts.printTrace then console.debug("consistentTransitions",consistentTransitions)
			return consistentTransitions

		_makeTransitionsConsistent: (transitions) ->
			consistentTransitions = new @opts.TransitionSet()

			[transitionsNotInConflict, transitionsPairsInConflict] = @_getTransitionsInConflict transitions
			consistentTransitions.union transitionsNotInConflict

			if @opts.printTrace then console.debug "transitions",transitions
			if @opts.printTrace then console.debug "transitionsNotInConflict",transitionsNotInConflict
			if @opts.printTrace then console.debug "transitionsPairsInConflict",transitionsPairsInConflict
			if @opts.printTrace then console.debug "consistentTransitions",consistentTransitions

			while not transitionsPairsInConflict.isEmpty()

				transitions = new @opts.TransitionSet(@opts.priorityComparisonFn t for t in transitionsPairsInConflict.iter())

				[transitionsNotInConflict, transitionsPairsInConflict] = @_getTransitionsInConflict transitions

				consistentTransitions.union transitionsNotInConflict

				if @opts.printTrace then console.debug "transitions",transitions
				if @opts.printTrace then console.debug "transitionsNotInConflict",transitionsNotInConflict
				if @opts.printTrace then console.debug "transitionsPairsInConflict",transitionsPairsInConflict
				if @opts.printTrace then console.debug "consistentTransitions",consistentTransitions

			return consistentTransitions
				
		_getTransitionsInConflict: (transitions) ->

			allTransitionsInConflict = new @opts.TransitionSet()
			transitionsPairsInConflict = new @opts.TransitionPairSet() 	#set of tuples

			#better to use iterators, because not sure how to encode "order doesn't matter" to list comprehension
			transitionList = transitions.iter()
			if @opts.printTrace then console.debug("transitions",transitionList)

			for i in [0...transitionList.length]
				for j in [i+1...transitionList.length]
					t1 = transitionList[i]
					t2 = transitionList[j]
					
					if @_conflicts(t1,t2)
						allTransitionsInConflict.add t1
						allTransitionsInConflict.add t2
						transitionsPairsInConflict.add [t1,t2]

			transitionsNotInConflict = transitions.difference allTransitionsInConflict

			return [transitionsNotInConflict,transitionsPairsInConflict]
		

		#this would be parameterizable
		# -> Transition Consistency: Small-step consistency: Source/Destination Orthogonal
		# -> Interrupt Transitions and Preemption: Non-preemptive 
		_conflicts: (t1,t2) -> not @_isArenaOrthogonal(t1,t2)
		
		_isArenaOrthogonal: (t1,t2) ->
			t1LCA = @opts.model.getLCA(t1)
			t2LCA = @opts.model.getLCA(t2)
			isOrthogonal = @opts.model.isOrthogonalTo t1LCA,t2LCA
			if @opts.printTrace
				console.debug "transition LCAs",t1LCA.id,t2LCA.id
				console.debug "transition LCAs are orthogonal?",isOrthogonal
			return isOrthogonal


	class SimpleInterpreter extends SCXMLInterpreter

		constructor: (model,@setTimeout,@clearTimeout,opts) ->
			super model,opts
			
		_evaluateAction: (action,eventSet,datamodelForNextStep,eventsToAddToInnerQueue) ->
			if action.type is "send" and action.delay
				if @setTimeout
					if @opts.printTrace then console.debug "sending event",action.event,"with content",action.contentexpr,"after delay",action.delay
					data = if action.contentexpr then @_eval(action,datamodelForNextStep,eventSet) else null

					callback = => @gen new Event(action.event,data)
					timeoutId = @setTimeout callback,action.delay

					if action.id
						@_timeoutMap[action.id] = timeoutId
				else
					throw new Error("setTimeout function not set")

			else if action.type is "cancel"
				if @clearTimeout
					if action.sendid of @_timeoutMap
						if @opts.printTrace then console.debug "cancelling ",action.id," with timeout id ",@_timeoutMap[action.id]
						@clearTimeout @_timeoutMap[action.id]
				else
					throw new Error("clearTimeout function not set")
			else
				super action,eventSet,datamodelForNextStep,eventsToAddToInnerQueue

		#External Event Communication: Asynchronous
		gen: (e) ->
			#pass it straight through	
			if @opts.printTrace then console.debug("received event " + e)
			@_performBigStep(e)

	class BrowserInterpreter extends SimpleInterpreter
		constructor : (model,opts={}) ->
			#need to wrap setTimeout and clearTimeout, otherwise complains
			setTimeout = (callback,timeout) -> window.setTimeout callback,timeout
			clearTimeout = (timeoutId) -> window.clearTimeout timeoutId

			#defaults
			setupDefaultOpts opts

			super model,setTimeout,clearTimeout,opts

	class NodeInterpreter extends SimpleInterpreter
		constructor : (model,opts={}) ->

			#defaults
			setupDefaultOpts opts

			super model,setTimeout,clearTimeout,opts

	SCXMLInterpreter:SCXMLInterpreter
	SimpleInterpreter:SimpleInterpreter
	BrowserInterpreter:BrowserInterpreter
	NodeInterpreter:NodeInterpreter
