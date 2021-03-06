namespace UnityScript.Steps

import Boo.Lang.Compiler
import Boo.Lang.Compiler.Ast
import Boo.Lang.Compiler.TypeSystem
import Boo.Lang.Compiler.TypeSystem.Internal
import Boo.Lang.Compiler.Steps

import Boo.Lang.Environments

import UnityScript.Core
import UnityScript.Macros
import UnityScript.TypeSystem

class ProcessUnityScriptMethods(ProcessMethodBodiesWithDuckTyping):
	
	deferred IEnumerable_GetEnumerator = Types.IEnumerable.GetMethod("GetEnumerator");
		
	deferred IEnumerator_MoveNext = Types.IEnumerator.GetMethod("MoveNext");
		
	deferred IEnumerator_get_Current = Types.IEnumerator.GetProperty("Current").GetGetMethod();
	
	deferred _StartCoroutine = NameResolutionService.ResolveMethod(UnityScriptTypeSystem.ScriptBaseType, "StartCoroutine_Auto")		
	
	deferred _UnityRuntimeServices_GetEnumerator = ResolveUnityRuntimeMethod("GetEnumerator")													
	
	deferred _UnityRuntimeServices_Update = ResolveUnityRuntimeMethod("Update")
	
	deferred _UnityRuntimeServices_GetTypeOf = ResolveUnityRuntimeMethod("GetTypeOf")
	
	_implicit = false
	
	override def Initialize(context as CompilerContext):
		super(context)
				
		// don't transform
		//     foo == null
		// into:
		//     foo is null
		// but into:
		//     foo.Equals(null)						
		self.OptimizeNullComparisons = false
		
	def ResolveUnityRuntimeMethod(name as string):
		return NameResolutionService.ResolveMethod(UnityRuntimeServicesType, name)
		
	def ResolveUnityRuntimeField(name as string):
		return NameResolutionService.ResolveField(UnityRuntimeServicesType, name)
		
	deferred UnityRuntimeServicesType = TypeSystemServices.Map(UnityScript.Lang.UnityRuntimeServices)
		
	UnityScriptTypeSystem as UnityScript.TypeSystem.UnityScriptTypeSystem:
		get: return self.TypeSystemServices
			
	UnityScriptParameters as UnityScript.UnityScriptCompilerParameters:
		get: return _context.Parameters
		
	override def GetGeneratorReturnType(generator as InternalMethod):
		return TypeSystemServices.IEnumeratorType
			
	override def IsDuckTyped(e as Expression):
		if Strict: return false
		return super(e)
		
	override def IsDuckTyped(member as IMember):
		if Strict: return false
		return super(member)
		
	override protected def MemberNotFound(node as MemberReferenceExpression, ns as INamespace):
		if Strict:			
			super(node, ns)
		else:
			BindQuack(node)
		
	override protected def LocalToReuseFor(d as Declaration):
		if DeclarationAnnotations.ShouldForceNewVariableFor(d):
			AssertUniqueLocal(d)
			return null
		return super(d)
				
	override def OnModule(module as Module):  
		preserving _activeModule, Parameters.Strict, _implicit, my(UnityDowncastPermissions).Enabled:
			EnterModuleContext(module)
			super(module)
			
	override def VisitMemberPreservingContext(node as TypeMember):
		
		module = node.EnclosingModule
		if module is _activeModule:
			super(node)
			return
			
		preserving _activeModule, Parameters.Strict, _implicit, my(UnityDowncastPermissions).Enabled:
			EnterModuleContext(module)
			super(node)
			
	private def EnterModuleContext(module as Module):
		_activeModule = module
		Parameters.Strict = Pragmas.IsEnabledOn(module, Pragmas.Strict)
		_implicit = Pragmas.IsEnabledOn(module, Pragmas.Implicit)
		my(UnityDowncastPermissions).Enabled = Pragmas.IsEnabledOn(module, Pragmas.Downcast)

	_activeModule as Module
	
	Strict:
		get: return Parameters.Strict
		
	override def OnMethod(node as Method):
		super(node)
		CheckForEmptyCoroutine(node)
		return if Parameters.OutputType == CompilerOutputType.Library
		CheckEntryPoint(node)
		
	def CheckForEmptyCoroutine(node as Method):
		if not IsEmptyCoroutine(node):
			return
		node.Body.Add([| return $(EmptyEnumeratorReference) |])
			
	def IsEmptyCoroutine(node as Method):
		entity as InternalMethod = GetEntity(node)
		return entity.ReturnType is GetGeneratorReturnType(entity) and HasNeitherReturnNorYield(node)
		
	deferred EmptyEnumeratorReference = CodeBuilder.CreateMemberReference(ResolveUnityRuntimeField("EmptyEnumerator"))
		
	def CheckEntryPoint(node as Method):
		if not node.IsStatic: return
		if not node.IsPublic: return
		if node.Name != "Main": return
		if GetType(node.ReturnType) is not TypeSystemServices.VoidType: return
		
		ContextAnnotations.SetEntryPoint(_context, node)
		
	override def ProcessAutoLocalDeclaration(node as BinaryExpression, reference as ReferenceExpression):
		if (Strict and not _implicit) and not IsCompilerGenerated(reference):
			EmitUnknownIdentifierError(reference, reference.Name)
		else:
			super(node, reference)
			
	def IsCompilerGenerated(reference as ReferenceExpression):
		return reference.Name.Contains('$')
		
	override protected def ProcessBuiltinInvocation(node as MethodInvocationExpression, function as BuiltinFunction):
		if function is UnityScriptTypeSystem.UnityScriptEval:
			EvalAnnotation.Mark(_currentMethod.Method)
			BindExpressionType(node, TypeSystemServices.ObjectType)
			return
		if function is UnityScriptTypeSystem.UnityScriptTypeof:
			ProcessTypeofBuiltin(node);
			return
		super(node, function)
		
	private def ProcessTypeofBuiltin(node as MethodInvocationExpression):
		if node.Arguments.Count != 1:
			Error(node, CompilerError("UCE0001", node.Target.LexicalInfo, "'typeof' takes a single argument.", null))
			return
		
		type = node.Arguments[0].Entity as IType
		if type is not null:
			node.ParentNode.Replace(node, CodeBuilder.CreateTypeofExpression(type))
			return
			
		node.Target = CodeBuilder.CreateReference(_UnityRuntimeServices_GetTypeOf)
		BindExpressionType(node, TypeSystemServices.TypeType)		
		
	override protected def ProcessMethodInvocation(node as MethodInvocationExpression, method as IMethod):
	"""
	Automatically detects coroutine invocations in assignments and as standalone
	expressions and generates StartCoroutine invocations.
	"""
		super(node, method)
		
		if not IsPossibleStartCoroutineInvocation(node):
			return		

		if method.IsStatic: return		
		
		tss = self.UnityScriptTypeSystem
		if not tss.IsScriptType(method.DeclaringType): return		
		if not tss.IsGenerator(method): return
		
		parentNode = node.ParentNode
		parentNode.Replace(
			node,
			CodeBuilder.CreateMethodInvocation(
				TargetForStartCoroutineInvocation(node, method),
				_StartCoroutine,
				node))
				
	def TargetForStartCoroutineInvocation(node as MethodInvocationExpression, method as IMethod):
		target = cast(MemberReferenceExpression, node.Target).Target
		if target isa SuperLiteralExpression: // super becomes self for coroutine invocation
			return CodeBuilder.CreateSelfReference(target.LexicalInfo, method.DeclaringType)
		return target.CloneNode()
				
	override def ProcessStaticallyTypedAssignment(node as BinaryExpression):
		TryToResolveAmbiguousAssignment(node)		
		ApplyImplicitArrayConversion(node)
		if ValidateAssignment(node):
			BindExpressionType(node, GetExpressionType(node.Right))
		else:
			Error(node)
		
	def ApplyImplicitArrayConversion(node as BinaryExpression):
		left = GetExpressionType(node.Left)
		if not left.IsArray: return
				
		right = GetExpressionType(node.Right)
		if right is not TypeSystemServices.Map(UnityScript.Lang.Array): return

		node.Right = CodeBuilder.CreateCast(left, 
						CodeBuilder.CreateMethodInvocation(
							node.Right,
							ResolveMethod(right, "ToBuiltin"),
							CodeBuilder.CreateTypeofExpression(left.ElementType)))
				
	override def OnForStatement(node as ForStatement):
		assert 1 == len(node.Declarations)
		Visit(node.Iterator)
		if NeedsUpdateableIteration(node):
			ProcessUpdateableIteration(node)
		else:
			ProcessNormalIteration(node)

	def ProcessNormalIteration(node as ForStatement):
		node.Iterator = ProcessIterator(node.Iterator, node.Declarations)
		VisitForStatementBlock(node)
		
	def ProcessUpdateableIteration(node as ForStatement):
		newIterator = CodeBuilder.CreateMethodInvocation(_UnityRuntimeServices_GetEnumerator, node.Iterator)
		newIterator.LexicalInfo = LexicalInfo(node.Iterator.LexicalInfo)
		node.Iterator = newIterator
		ProcessDeclarationForIterator(node.Declarations[0], TypeSystemServices.ObjectType)
		VisitForStatementBlock(node)
		TransformIteration(node)

	def TransformIteration(node as ForStatement):
		iterator = CodeBuilder.DeclareLocal(
						_currentMethod.Method,
						_context.GetUniqueName("iterator"),
						TypeSystemServices.IEnumeratorType)
		iterator.IsUsed = true
		body = Block(node.LexicalInfo)
		body.Add(
			CodeBuilder.CreateAssignment(
				node.LexicalInfo,
				CodeBuilder.CreateReference(iterator),
				node.Iterator))
				
		// while __iterator.MoveNext():
		ws = WhileStatement(node.LexicalInfo)
		ws.Condition = CodeBuilder.CreateMethodInvocation(
						CodeBuilder.CreateReference(iterator),
						IEnumerator_MoveNext)
			
		current = CodeBuilder.CreateMethodInvocation(
							CodeBuilder.CreateReference(iterator),
							IEnumerator_get_Current)
			
		//	item = __iterator.Current
		loopVariable as InternalLocal = TypeSystemServices.GetEntity(node.Declarations[0])
		ws.Block.Add(
				CodeBuilder.CreateAssignment(
					node.LexicalInfo,
					CodeBuilder.CreateReference(loopVariable),
					current))
		ws.Block.Add(node.Block)			
		
		LoopVariableUpdater(self, _context, iterator, loopVariable).Visit(node)
		
		body.Add(ws)
		node.ParentNode.Replace(node, body)
		
	def NeedsUpdateableIteration(node as ForStatement):
		iteratorType = GetExpressionType(node.Iterator)
		if iteratorType.IsArray: return false
		return true
		
	class LoopVariableUpdater(DepthFirstVisitor):
		
		_parent as ProcessUnityScriptMethods
		_context as CompilerContext
		_iteratorVariable as IEntity
		_loopVariable as IEntity
		_found as bool
		
		def constructor(parent as ProcessUnityScriptMethods, context as CompilerContext, iteratorVariable as IEntity, loopVariable as IEntity):
			_parent = parent
			_context = context
			_iteratorVariable = iteratorVariable
			_loopVariable = loopVariable
			
		override def OnExpressionStatement(node as ExpressionStatement):
			_found = false
			Visit(node.Expression)
			if not _found: return
			
			parentNode = node.ParentNode
			
			codeBuilder = _context.CodeBuilder
			block = Block(node.LexicalInfo)
			block.Add(node)
			block.Add(
				codeBuilder.CreateMethodInvocation(
					_parent._UnityRuntimeServices_Update, 
					codeBuilder.CreateReference(_iteratorVariable),
					codeBuilder.CreateReference(_loopVariable)))

			parentNode.Replace(node, block)
			
		override def OnReferenceExpression(node as ReferenceExpression):
			if _found: return
			
			referent = node.Entity
			_found = referent is _loopVariable
