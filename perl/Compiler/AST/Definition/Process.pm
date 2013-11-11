package Compiler::AST::Definition::Process;

use strict;
use warnings FATAL => 'all';

use UR;
use Carp qw(confess);

use Genome::WorkflowBuilder::DAG;
use Memoize qw();


class Compiler::AST::Definition::Process {
    is => 'Compiler::AST::Definition',

    has => [
        nodes => {
            is => 'Compiler::AST::Node',
            is_many => 1,
        },
    ],

    has_transient => {
        _used_producer_ids => {
            is => 'HASH',
            is_optional => 1,
            default_value => {},
        },
        _satisfied_consumer_ids => {
            is => 'HASH',
            is_optional => 1,
            default_value => {},
        },
    },
};

sub workflow_builder {
    my ($self, $alias) = @_;

    $self->_used_producer_ids({});
    $self->_satisfied_consumer_ids({});

    my $dag = Genome::WorkflowBuilder::DAG->create(name => $alias);

    $self->_add_operations_to($dag);

    $self->_add_explicit_links_to($dag);
    $self->_add_implicit_links_to($dag);

    return $dag;
}
Memoize::memoize('workflow_builder');

sub inputs {
    my $self = shift;

    # NOTE: This is how we figure out which consumers are unsatisfied
    $self->workflow_builder('');

    my @result;
    for my $data_type ($self->_involved_data_types) {
        my $consumers = $self->_unsatisfied_consumers_of($data_type);
        if (scalar(@$consumers)) {
            push @result, Compiler::AST::IO::Input->create(
                type => $data_type,
                name => $self->_automatic_property_name($consumers),
            );
        }
    }

    return @result;
}

sub outputs {
    my $self = shift;

    # NOTE: This is how we figure out which producers are unused
    $self->workflow_builder('');

    my @result;
    for my $data_type ($self->_involved_data_types) {
        my $producers = $self->_unused_producers_of($data_type);
        if (scalar(@$producers)) {
            push @result, Compiler::AST::IO::Output->create(
                type => $data_type,
                name => $self->_automatic_property_name($producers),
            );
        }
    }

    return @result;
}

sub _add_operations_to {
    my ($self, $dag) = @_;

    for my $node ($self->nodes) {
        $dag->add_operation($node->workflow_builder);
    }
    return;
}

sub _add_explicit_links_to {
    my ($self, $dag) = @_;

    for my $node ($self->nodes) {
        for my $explicit_link ($node->explicit_internal_links) {
            my $producer = $self->_producer_from_link_to_node(
                $explicit_link, $node);
            my $consumer = $self->_consumer_from_node_and_link(
                $node, $explicit_link);
            $self->_create_link($dag, $producer, $consumer);
        }

        for my $explicit_input ($node->explicit_inputs) {
            my $consumer = $self->_consumer_from_node_and_link(
                $node, $explicit_input);
            $dag->connect_input(
                input_property => $self->_automatic_property_name([$consumer]),
                destination => $consumer->workflow_builder,
                destination_property => $consumer->property_name,
            );
        }
    }

    return;
}

sub _producer_from_link_to_node {
    my ($self, $link, $destination) = @_;

    my $node = $self->_node_aliased($link->source);
    my $property_name = $node->unique_output_of_type(
        $destination->type_of($link->property_name));

    return Compiler::AST::Detail::DataEndPoint->create(
        node => $node, property_name => $property_name);
}

sub _node_aliased {
    my ($self, $alias) = @_;

    my @result = grep {$_->alias eq $alias} $self->nodes;
    unless (scalar(@result) == 1) {
        confess sprintf("Didn't find exactly 1 node aliased %s", $alias);
    }

    return $result[0];
}

sub _consumer_from_node_and_link {
    my ($self, $node, $link) = @_;

    return Compiler::AST::Detail::DataEndPoint->create(
        node => $node, property_name => $link->property_name);
}

sub _add_implicit_links_to {
    my ($self, $dag) = @_;

    for my $data_type ($self->_involved_data_types) {
        $self->_add_implicit_links_for_data_type_to($data_type, $dag);
    }

    return;
}

sub _involved_data_types {
    my $self = shift;
    my %data_types;

    for my $node ($self->nodes) {
        for my $input ($node->inputs) {
            $data_types{$input->type} = 1;
        }

        for my $output ($node->outputs) {
            $data_types{$output->type} = 1;
        }
    }

    return keys %data_types;
}
Memoize::memoize('_involved_data_types');


sub _add_implicit_links_for_data_type_to {
    my ($self, $data_type, $dag) = @_;

    my $consumers = $self->_unsatisfied_consumers_of($data_type);
    my $producers = $self->_unused_producers_of($data_type);

    if (scalar(@$producers) == 1) {
        $self->_add_implicit_links_between($dag, $producers->[0], $consumers);

    } elsif (scalar(@$producers) > 1) {
        confess sprintf("Ambiguity:  Found multiple unused producers "
            . "for data type (%s): [%s]", $data_type,
            join(', ', map {sprintf("'%s'", $_->alias)} @$producers));

    } else {
        if (scalar(@$consumers)) {
            $self->_add_implicit_input($dag, $consumers);
        } else {
            # No producers or consumers for this data type.
        }
    }

    return;
}

sub _add_implicit_links_between {
    my ($self, $dag, $producer, $consumers) = @_;

    if (scalar(@$consumers)) {
        for my $consumer (@$consumers) {
            $self->_create_link($dag, $producer, $consumer);
        }
    } else {
        $self->_add_implicit_output($dag, $producer);
    }

    return;
}

sub _add_implicit_output {
    my ($self, $dag, $producer) = @_;

    $dag->connect_output(
        output_property => $self->_automatic_property_name([$producer]),
        source => $producer->workflow_builder,
        source_property => $producer->property_name,
    );

    return;
}

sub _add_implicit_input {
    my ($self, $dag, $consumers) = @_;

    my $input_name = $self->_automatic_property_name($consumers);
    for my $consumer (@$consumers) {
        $dag->connect_input(
            input_property => $input_name,
            destination => $consumer->workflow_builder,
            destination_property => $consumer->property_name,
        );
    }

    return;
}

sub _automatic_property_name {
    my ($self, $data_end_points) = @_;

    if (scalar(@$data_end_points) > 1) {
        return sprintf("(%s)", join("+",
                map {$self->_automatic_property_name_component($_)}
                @$data_end_points));
    } elsif (scalar(@$data_end_points) == 1) {
        return $self->_automatic_property_name_component($data_end_points->[0]);
    } else {
        confess "Require at least one data end point to compute input name";
    }
}

sub _automatic_property_name_component {
    my ($self, $data_end_point) = @_;

    unless (defined($data_end_point)) {
        confess "Got undefined value for data_end_point";
    }

    return sprintf("%s.%s", $data_end_point->alias,
        $data_end_point->property_name);
}

sub _unsatisfied_consumers_of {
    my ($self, $data_type) = @_;

    my $consumers = $self->_consumers_of($data_type);

    my @result;
    for my $consumer (@$consumers) {
        unless (exists $self->_satisfied_consumer_ids->{$consumer->id}) {
            push @result, $consumer;
        }
    }

    return \@result;
}

sub _consumers_of {
    my ($self, $data_type) = @_;
    return [map {$_->inputs_of($data_type)} $self->nodes];
}

sub _unused_producers_of {
    my ($self, $data_type) = @_;

    my $producers = $self->_producers_of($data_type);

    my @result;
    for my $producer (@$producers) {
        unless (exists $self->_used_producer_ids->{$producer->id}) {
            push @result, $producer;
        }
    }

    return \@result;
}

sub _producers_of {
    my ($self, $data_type) = @_;
    return [map {$_->outputs_of($data_type)} $self->nodes];
}


sub _create_link {
    my ($self, $dag, $producer, $consumer) = @_;

    $self->_use($producer);
    $self->_satisfy($consumer);

    $dag->create_link(
        source => $producer->workflow_builder,
        source_property => $producer->property_name,
        destination => $consumer->workflow_builder,
        destination_property => $consumer->property_name,
    );

    return;
}

sub _use {
    my ($self, $producer) = @_;

    $self->_used_producer_ids->{$producer->id} = 1;

    return;
}

sub _satisfy {
    my ($self, $consumer) = @_;

    $self->_satisfied_consumer_ids->{$consumer->id} = 1;

    return;
}


1;