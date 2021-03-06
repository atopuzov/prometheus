// Copyright 2013 The Prometheus Authors
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

%{
        package rules

        import (
          clientmodel "github.com/prometheus/client_golang/model"

          "github.com/prometheus/prometheus/rules/ast"
          "github.com/prometheus/prometheus/storage/metric"
        )
%}

%union {
        num clientmodel.SampleValue
        str string
        ruleNode ast.Node
        ruleNodeSlice []ast.Node
        boolean bool
        labelNameSlice clientmodel.LabelNames
        labelSet clientmodel.LabelSet
        labelMatcher *metric.LabelMatcher
        labelMatchers metric.LabelMatchers
        vectorMatching *vectorMatching
}

/* We simulate multiple start symbols for closely-related grammars via dummy tokens. See
   http://www.gnu.org/software/bison/manual/html_node/Multiple-start_002dsymbols.html
   Reason: we want to be able to parse lists of named rules as well as single expressions.
   */
%token START_RULES START_EXPRESSION

%token <str> IDENTIFIER STRING DURATION METRICNAME
%token <num> NUMBER
%token PERMANENT GROUP_OP KEEPING_EXTRA OFFSET MATCH_OP
%token <str> AGGR_OP CMP_OP ADDITIVE_OP MULT_OP MATCH_MOD
%token ALERT IF FOR WITH SUMMARY DESCRIPTION

%type <ruleNodeSlice> func_arg_list
%type <labelNameSlice> label_list grouping_opts
%type <labelSet> label_assign label_assign_list rule_labels
%type <labelMatcher> label_match
%type <labelMatchers> label_match_list label_matches
%type <vectorMatching> vector_matching
%type <ruleNode> rule_expr func_arg
%type <boolean> qualifier extra_labels_opts
%type <str> for_duration metric_name label_match_type offset_opts

%right '='
%left CMP_OP
%left ADDITIVE_OP
%left MULT_OP
%start start

%%
start              : START_RULES rules_stat_list
                   | START_EXPRESSION saved_rule_expr
                   ;

rules_stat_list    : /* empty */
                   | rules_stat_list rules_stat
                   ;

saved_rule_expr    : rule_expr
                     { yylex.(*RulesLexer).parsedExpr = $1 }
                   ;


rules_stat         : qualifier metric_name rule_labels '=' rule_expr
                     {
                       rule, err := CreateRecordingRule($2, $3, $5, $1)
                       if err != nil { yylex.Error(err.Error()); return 1 }
                       yylex.(*RulesLexer).parsedRules = append(yylex.(*RulesLexer).parsedRules, rule)
                     }
                   | ALERT IDENTIFIER IF rule_expr for_duration WITH rule_labels SUMMARY STRING DESCRIPTION STRING
                     {
                       rule, err := CreateAlertingRule($2, $4, $5, $7, $9, $11)
                       if err != nil { yylex.Error(err.Error()); return 1 }
                       yylex.(*RulesLexer).parsedRules = append(yylex.(*RulesLexer).parsedRules, rule)
                     }
                   ;

for_duration       : /* empty */
                     { $$ = "0s" }
                   | FOR DURATION
                     { $$ = $2 }
                   ;

qualifier          : /* empty */
                     { $$ = false }
                   | PERMANENT
                     { $$ = true }
                   ;

metric_name        : METRICNAME
                     { $$ = $1 }
                   | IDENTIFIER
                     { $$ = $1 }
                   ;

rule_labels        : /* empty */
                     { $$ = clientmodel.LabelSet{} }
                   | '{' label_assign_list '}'
                     { $$ = $2  }
                   | '{' '}'
                     { $$ = clientmodel.LabelSet{} }

label_assign_list  : label_assign
                     { $$ = $1 }
                   | label_assign_list ',' label_assign
                     { for k, v := range $3 { $$[k] = v } }
                   ;

label_assign       : IDENTIFIER '=' STRING
                     { $$ = clientmodel.LabelSet{ clientmodel.LabelName($1): clientmodel.LabelValue($3) } }
                   ;

label_matches      : /* empty */
                     { $$ = metric.LabelMatchers{} }
                   | '{' '}'
                     { $$ = metric.LabelMatchers{} }
                   | '{' label_match_list '}'
                     { $$ = $2 }
                   ;

label_match_list   : label_match
                     { $$ = metric.LabelMatchers{$1} }
                   | label_match_list ',' label_match
                     { $$ = append($$, $3) }
                   ;

label_match        : IDENTIFIER label_match_type STRING
                     {
                       var err error
                       $$, err = newLabelMatcher($2, clientmodel.LabelName($1), clientmodel.LabelValue($3))
                       if err != nil { yylex.Error(err.Error()); return 1 }
                     }
                   ;

label_match_type   : '='
                     { $$ = "=" }
                   | CMP_OP
                     { $$ = $1 }
                   ;

offset_opts        : /* empty */
                     { $$ = "0s" }
                   | OFFSET DURATION
                     { $$ = $2 }
                   ;

rule_expr          : '(' rule_expr ')'
                     { $$ = $2 }
                   | '{' label_match_list '}' offset_opts
                     {
                       var err error
                       $$, err = NewVectorSelector($2, $4)
                       if err != nil { yylex.Error(err.Error()); return 1 }
                     }
                   | metric_name label_matches offset_opts
                     {
                       var err error
                       m, err := metric.NewLabelMatcher(metric.Equal, clientmodel.MetricNameLabel, clientmodel.LabelValue($1))
                       if err != nil { yylex.Error(err.Error()); return 1 }
                       $2 = append($2, m)
                       $$, err = NewVectorSelector($2, $3)
                       if err != nil { yylex.Error(err.Error()); return 1 }
                     }
                   | IDENTIFIER '(' func_arg_list ')'
                     {
                       var err error
                       $$, err = NewFunctionCall($1, $3)
                       if err != nil { yylex.Error(err.Error()); return 1 }
                     }
                   | IDENTIFIER '(' ')'
                     {
                       var err error
                       $$, err = NewFunctionCall($1, []ast.Node{})
                       if err != nil { yylex.Error(err.Error()); return 1 }
                     }
                   | rule_expr '[' DURATION ']' offset_opts
                     {
                       var err error
                       $$, err = NewMatrixSelector($1, $3, $5)
                       if err != nil { yylex.Error(err.Error()); return 1 }
                     }
                   | AGGR_OP '(' rule_expr ')' grouping_opts extra_labels_opts
                     {
                       var err error
                       $$, err = NewVectorAggregation($1, $3, $5, $6)
                       if err != nil { yylex.Error(err.Error()); return 1 }
                     }
                   | AGGR_OP grouping_opts extra_labels_opts '(' rule_expr ')'
                     {
                       var err error
                       $$, err = NewVectorAggregation($1, $5, $2, $3)
                       if err != nil { yylex.Error(err.Error()); return 1 }
                     }
                   /* Yacc can only attach associativity to terminals, so we
                    * have to list all operators here. */
                   | rule_expr ADDITIVE_OP vector_matching rule_expr
                     {
                       var err error
                       $$, err = NewArithExpr($2, $1, $4, $3)
                       if err != nil { yylex.Error(err.Error()); return 1 }
                     }
                   | rule_expr MULT_OP vector_matching rule_expr
                     {
                       var err error
                       $$, err = NewArithExpr($2, $1, $4, $3)
                       if err != nil { yylex.Error(err.Error()); return 1 }
                     }
                   | rule_expr CMP_OP vector_matching rule_expr
                     {
                       var err error
                       $$, err = NewArithExpr($2, $1, $4, $3)
                       if err != nil { yylex.Error(err.Error()); return 1 }
                     }
                   | NUMBER
                     { $$ = NewScalarLiteral($1, "+")}
                   | ADDITIVE_OP NUMBER
                     { $$ = NewScalarLiteral($2, $1)}
                   ;

extra_labels_opts  : /* empty */
                     { $$ = false }
                   | KEEPING_EXTRA
                     { $$ = true }
                   ;

vector_matching    : /* empty */
                     { $$ = nil }
                   | MATCH_OP '(' label_list ')'
                     {
                       var err error
                       $$, err = newVectorMatching("", $3, nil)
                       if err != nil { yylex.Error(err.Error()); return 1 }
                     }
                   | MATCH_OP '(' label_list ')' MATCH_MOD '(' label_list ')'
                     {
                       var err error
                       $$, err = newVectorMatching($5, $3, $7)
                       if err != nil { yylex.Error(err.Error()); return 1 }
                     }
                   ;

grouping_opts      :
                     { $$ = clientmodel.LabelNames{} }
                   | GROUP_OP '(' label_list ')'
                     { $$ = $3 }
                   ;

label_list         : IDENTIFIER
                     { $$ = clientmodel.LabelNames{clientmodel.LabelName($1)} }
                   | label_list ',' IDENTIFIER
                     { $$ = append($$, clientmodel.LabelName($3)) }
                   ;

func_arg_list      : func_arg
                     { $$ = []ast.Node{$1} }
                   | func_arg_list ',' func_arg
                     { $$ = append($$, $3) }
                   ;

func_arg           : rule_expr
                     { $$ = $1 }
                   | STRING
                     { $$ = ast.NewStringLiteral($1) }
                   ;
%%
