package TemplateImport::CMS;
use strict;

use MT::Util qw( is_valid_url );

sub dialog_add_template_set {
    my $app  = shift;
    my $blog = $app->blog;
    return $app->errtrans('Invalid request.') unless $blog;
    return $app->return_to_dashboard( permission => 1 )
        unless $app->can_do('open_theme_listing_screen');

    require MT::Theme;
    my $all_theme = MT::Theme->load_all_themes();
    my $current = $blog->theme || '';

    my @data;
    foreach my $theme ( values %$all_theme ) {
        next if $theme->id eq $current->id;
        next unless $theme->{elements}->{template_set};
        next
            if !$theme->{class}
                || ($theme->{class} ne 'both'
                    && (  $blog->is_blog
                        ? $theme->{class} eq 'website'
                        : $theme->{class} eq 'blog'
                    )
                );

        my $row;
        $row->{id} = $row->{theme_id} = $theme->id;
        $row->{label} = ref $theme->label ? $theme->label->() : $theme->label;
        $row->{name}          = $theme->name || $theme->label;
        $row->{description}   = $theme->description;
        $row->{theme_version} = $theme->{version};
        $row->{author_name}   = $theme->{author_name} || '';
        $row->{author_link}   = $theme->{author_link}
            if is_valid_url( $theme->{author_link} );
        $row->{version} = $theme->{version};

        my ($thumbnail_url) = $theme->thumbnail( size => 'small' );
        $row->{thumbnail_url} = $thumbnail_url;

        push @data, $row;
    }
    @data = sort { $a->{label} cmp $b->{label} } @data;

    my %param;
    $param{theme_loop} = \@data;
    $param{return_args} = $app->param('return_args') || '';
    $app->load_tmpl( 'select_theme.tmpl', \%param );
}

sub import_template_set {
    my $app  = shift;
    my $blog = $app->blog;
    return $app->errtrans('Invalid request.') unless $blog;
    $app->validate_magic() or return;

    return $app->return_to_dashboard( permission => 1 )
        unless $app->can_do('apply_theme');

    my $user_lang = MT->current_language;
    $app->set_language(
        $blog ? $blog->language : MT->config->DefaultLanguage );

    require MT::Log;
    require MT::Theme;
    require MT::Template;
    require MT::DefaultTemplates;
    my @id = $app->param('import_theme');
    my $tmpl_list;
    foreach my $id (@id) {
        my $theme = MT::Theme->load($id)
            or return $app->error( MT->translate('Theme not found') );

        my @elements = $theme->elements;
        my ($set) = grep { $_->{importer} eq 'template_set' } @elements;
        $set = $set->{data};
        next unless ref $set;
        $set->{envelope} = $theme->path;
        $theme->__deep_localize_labels($set);
        $tmpl_list = MT::DefaultTemplates->templates($set);
        next unless scalar @$tmpl_list;

        foreach my $tmpl (@$tmpl_list) {
            my $obj = MT::Template->new;
            my $p   = $tmpl->{plugin}
                || 'MT';    # component and/or MT package for translate
            local $tmpl->{name} = $tmpl
                ->{name};    # name field is translated in "templates" call
            my $text = $tmpl->{text};
            local $tmpl->{text};
            $tmpl->{text} = $p->translate_templatized($text) if defined $text;
            $obj->build_dynamic(0);
            foreach my $v ( keys %$tmpl ) {
                $obj->column( $v, $tmpl->{$v} ) if $obj->has_column($v);
            }
            $obj->blog_id( $blog->id );
            if ( my $pub_opts = $tmpl->{publishing} ) {
                $obj->include_with_ssi(1) if $pub_opts->{include_with_ssi};
            }
            if (   ( 'widgetset' eq $tmpl->{type} )
                && ( exists $tmpl->{widgets} ) )
            {
                my $modulesets = delete $tmpl->{widgets};
                $obj->modulesets(
                    MT::Template->widgets_to_modulesets(
                        $modulesets, $blog->id
                    )
                );
            }
            $obj->save
                or $app->log(
                {   message => $app->translate(
                        "Saving tempate('[_1]') failed: [_2]",
                        $obj->name, $obj->errstr
                    ),
                    level    => MT::Log::INFO(),
                    class    => 'template',
                    category => 'new',
                }
                );

            my @arch_tmpl;
            if ( $tmpl->{mappings} ) {
                push @arch_tmpl,
                    {
                    template => $obj,
                    mappings => $tmpl->{mappings},
                    exists( $tmpl->{preferred} )
                    ? ( preferred => $tmpl->{preferred} )
                    : ()
                    };
            }

            my %archive_types;
            if (@arch_tmpl) {
                require MT::TemplateMap;
                for my $map_set (@arch_tmpl) {
                    my $tmpl     = $map_set->{template};
                    my $mappings = $map_set->{mappings};
                    foreach my $map_key ( keys %$mappings ) {
                        my $m  = $mappings->{$map_key};
                        my $at = $m->{archive_type};
                        $archive_types{$at} = 1;

                        # my $preferred = $mappings->{$map_key}{preferred};
                        my $map = MT::TemplateMap->new;
                        $map->archive_type($at);
                        if ( exists $m->{preferred} ) {
                            $map->is_preferred( $m->{preferred} );
                        }
                        else {
                            $map->is_preferred(1);
                        }
                        $map->template_id( $tmpl->id );
                        $map->file_template( $m->{file_template} )
                            if $m->{file_template};
                        $map->blog_id( $tmpl->blog_id );
                        $map->build_type( $m->{build_type} )
                            if defined $m->{build_type};
                        $map->save;
                    }
                }
            }
        }
    }

    $app->set_language($user_lang);
    $app->call_return;
}

1;
