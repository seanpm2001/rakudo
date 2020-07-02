# Done by anything that implies a lexical scope.
class RakuAST::LexicalScope is RakuAST::Node {
    has List $!declarations-cache;
    has Mu $!lexical-lookup-hash;

    method IMPL-QAST-DECLS(RakuAST::IMPL::QASTContext $context) {
        my $stmts := QAST::Stmts.new();

        # Visit code objects that need to make a declaration entry.
        self.visit: :strict, -> $node {
            if nqp::istype($node, RakuAST::Code) {
                $stmts.push($node.IMPL-QAST-DECL-CODE($context));
            }
            !(nqp::istype($node, RakuAST::LexicalScope) || nqp::istype($node, RakuAST::IMPL::ImmediateBlockUser))
        }

        # Visit declarations.
        for self.IMPL-UNWRAP-LIST(self.lexical-declarations()) {
            $stmts.push($_.IMPL-QAST-DECL($context));
        }

        $stmts
    }

    method lexical-declarations() {
        unless nqp::isconcrete($!declarations-cache) {
            my @declarations;
            self.visit: -> $node {
                if nqp::istype($node, RakuAST::Declaration) && $node.is-lexical {
                    nqp::push(@declarations, $node);
                }
                if $node =:= self || !nqp::istype($node, RakuAST::LexicalScope) {
                    if nqp::istype($node, RakuAST::ImplicitDeclarations) {
                        for self.IMPL-UNWRAP-LIST($node.get-implicit-declarations()) -> $decl {
                            if $decl.is-lexical {
                                nqp::push(@declarations, $decl);
                            }
                        }
                    }
                    1 # visit children
                }
                else {
                    0 # it's an inner scope, don't visit its children
                }
            }
            nqp::bindattr(self, RakuAST::LexicalScope, '$!declarations-cache', @declarations);
        }
        $!declarations-cache
    }

    method find-lexical(Str $name) {
        my %lookup := $!lexical-lookup-hash;
        unless nqp::isconcrete(%lookup) {
            %lookup := {};
            for self.IMPL-UNWRAP-LIST(self.lexical-declarations) {
                %lookup{$_.lexical-name} := $_;
            }
            nqp::bindattr(self, RakuAST::LexicalScope, '$!lexical-lookup-hash', %lookup);
        }
        %lookup{$name} // Nil
    }
}

# Done by anything that is a declaration - that is, declares a symbol.
class RakuAST::Declaration is RakuAST::Node {
    has str $!scope;

    # Returns the default scope of this kind of declaration.
    method default-scope() {
        nqp::die('default-scope is not implemented on ' ~ self.HOW.name(self))
    }

    # Returns the list of allowed scopes for this kind of declaration.
    method allowed-scopes() {
        nqp::die('allowed-scopes is not implemented on ' ~ self.HOW.name(self))
    }

    # Gets the scope of this declaration.
    method scope() {
        my str $scope := $!scope;
        nqp::isnull_s($scope) || $scope eq ''
            ?? self.default-scope
            !! $scope
    }

    # Tests if this is a lexical declaration.
    method is-lexical() {
        my str $scope := self.scope;
        $scope eq 'my' || $scope eq 'state'
    }
}

# Done by anything that may make implicit declarations. For example, a package
# declares $?PACKAGE inside of it, a sub declares a fresh $_, $/, and $!, etc.
# While a declaration is considered something external to a node, and so exposed
# to the enclosing lexical scope, implicit declarations are considered as being
# on the inside; this makes a difference in the case the node is also doing
# RakuAST::LexicalScope and is thus a lexical scope boundary.
class RakuAST::ImplicitDeclarations is RakuAST::Node {
    has List $!implicit-declarations-cache;

    # A node typically implements this to specify the implicit declarations
    # that it makes. This is called once per instance of a node and then
    # remains constant. Nodes that may be mutated must instead implement
    # get-implicit-declarations and handle the caching themselves.
    method PRODUCE-IMPLICIT-DECLARATIONS() {
        self.IMPL-WRAP-LIST(nqp::list())
    }

    # Get a list of the implicit declarations.
    method get-implicit-declarations() {
        $!implicit-declarations-cache //
            nqp::bindattr(self, RakuAST::ImplicitDeclarations,
                '$!implicit-declarations-cache',
                self.PRODUCE-IMPLICIT-DECLARATIONS())
    }
}

# A lexical declaration that comes from an external symbol (for example, the
# setting or an EVAL).
class RakuAST::Declaration::External is RakuAST::Declaration {
    has str $.lexical-name;
    has Mu $!native-type;

    method new(str :$lexical-name, Mu :$native-type) {
        my $obj := nqp::create(self);
        nqp::bindattr_s($obj, RakuAST::Declaration::External, '$!lexical-name', $lexical-name);
        nqp::bindattr($obj, RakuAST::Declaration::External, '$!native-type', $native-type);
        $obj
    }

    method IMPL-LOOKUP-QAST(RakuAST::IMPL::QASTContext $context, Mu :$rvalue) {
        my str $scope := 'lexical';
        unless $rvalue {
            # Potentially l-value native lookups need a lexicalref.
            if nqp::objprimspec($!native-type) {
                $scope := 'lexicalref';
            }
        }
        QAST::Var.new( :name($!lexical-name), :$scope, :returns($!native-type) )
    }

    method default-scope() { 'my' }

    method allowed-scopes() { self.IMPL-WRAP-LIST(['my']) }
}

# A lexical declaration that comes with an external symbol, which has a fixed
# value available during compilation.
class RakuAST::Declaration::External::Constant is RakuAST::Declaration::External
        is RakuAST::CompileTimeValue {
    has Mu $.compile-time-value;

    method new(str :$lexical-name!, Mu :$compile-time-value!) {
        my $obj := nqp::create(self);
        nqp::bindattr_s($obj, RakuAST::Declaration::External, '$!lexical-name', $lexical-name);
        nqp::bindattr($obj, RakuAST::Declaration::External::Constant,
            '$!compile-time-value', $compile-time-value);
        $obj
    }

    method type() { $!compile-time-value.WHAT }
}

# Done by anything that is a lookup of a symbol. May or may not need resolution
# at compile time.
class RakuAST::Lookup is RakuAST::Node {
    has RakuAST::Declaration $!resolution;

    method needs-resolution() { True }

    method is-resolved() {
        nqp::isconcrete($!resolution) ?? True !! False
    }

    method resolution() {
        nqp::isconcrete($!resolution)
            ?? $!resolution
            !! nqp::die('This element has not been resolved')
    }

    method set-resolution(RakuAST::Declaration $resolution) {
        nqp::bindattr(self, RakuAST::Lookup, '$!resolution', $resolution)
    }
}

# Some program elements are not really lookups, but require the resolution
# of symbols as part of their compilation. For example, a positional regex
# access depends on `&postcircumfix:<[ ]>` and `$/`, while an `unless`
# statement depends on `Empty` (as that's what it evaluates to in the case
# there the condition is not matched).
class RakuAST::ImplicitLookups is RakuAST::Node {
    has List $!implicit-lookups-cache;

    # A node typically implements this to specify the implicit lookups
    # that it needs. This is called once per instance of a node and then
    # remains constant. Nodes that may be mutated must instead implement
    # get-implicit-lookups and handle the caching themselves.
    method PRODUCE-IMPLICIT-LOOKUPS() {
        self.IMPL-WRAP-LIST(nqp::list())
    }

    # Get a list of the implicit lookups.
    method get-implicit-lookups() {
        $!implicit-lookups-cache //
            nqp::bindattr(self, RakuAST::ImplicitLookups, '$!implicit-lookups-cache',
                self.PRODUCE-IMPLICIT-LOOKUPS())
    }

    # Resolve the implicit lookups if needed.
    method resolve-implicit-lookups-with(RakuAST::Resolver $resolver) {
        for self.IMPL-UNWRAP-LIST(self.get-implicit-lookups()) {
            unless $_.is-resolved {
                $_.resolve-with($resolver);
            }
        }
    }
}
